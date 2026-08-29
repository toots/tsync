(* The local cache-chunk store: {!Manifest.Group} bodies named by a content key
   derived from the stored chunks they hold.

   A group is present iff its file exists and may be deleted at any moment, so
   callers must treat a miss as ordinary (see {!read_into}). *)

(* Narrower than [Remote.S] so the store has no cycle with it and can be driven
   by a stub in tests. *)
(* What this needs below it: a filesystem, the syscalls that retry past EINTR,
   and pools to admit a few at a time. Each is a subset -- what the cache calls
   and nothing else. *)
module type FS = sig
  type 'a io

  val ensure_parent : string -> unit io
  val readdir_list : string -> string list io
  val unlink_quiet : string -> unit io
  val read : string -> Bigstring.t -> offset:int64 -> int io
  val write : string -> Bigstring.t -> offset:int64 -> int io
  val read_file_opt : string -> string option io
  val atomic_write : string -> string -> unit io

  val atomic_write_at :
    string ->
    size:int ->
    ((offset:int -> Bigstring.t -> unit io) -> unit io) ->
    unit io
end

module type SYSCALLS = sig
  type 'a io

  val file_exists : string -> bool io
  val stat : string -> Unix.stats io
  val link : string -> string -> unit io
  val utimes : string -> float -> float -> unit io
end

module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val use : t -> (unit -> 'a io) -> 'a io
  val map_with : t -> ('a -> 'b io) -> 'a list -> 'b list io
  val filter_map_with : t -> ('a -> 'b option io) -> 'a list -> 'b list io
end

module type Fetch = sig
  type 'a io

  val get_chunk : chunk_key:string -> Bigstring.t io

  val get_chunk_range :
    chunk_key:string -> offset:int -> length:int -> Bigstring.t io
end

(* What a read cost. Hoisted out of [Make]: it describes a read, not one
   store's state, and the staged half names it too.

   [fetched] is what crossed the wire, which is neither [bytes] nor the group's
   length: a read of a few bytes may pull a range, a whole group, or nothing at
   all. *)
type served = { bytes : int; fetched : int; from_backend : bool }

(* Which part of each stored chunk a partly filled body holds, in member-local
   coordinates.

   One interval per member and never a set: a fill that overlaps or sits apart
   from what is there takes in the ground between them, so the worst a read
   costs is one gap inside one stored chunk and there is no interval algebra to
   get wrong at three in the morning. *)
module Filled = struct
  type t = (int * (int * int)) list

  let empty = []
  let interval t i = List.assoc_opt i t
  let put t i span = (i, span) :: List.remove_assoc i t

  let render t =
    String.concat ""
      (List.map
         (fun (i, (a, b)) -> Printf.sprintf "%d %d %d\n" i a b)
         (List.sort compare t))

  (* Strict: anything unreadable is taken as an empty body rather than as the
     part of one it can still be parsed as. A manifest is rewritten whole, so a
     half-written one means a write was interrupted, and the safe reading of
     that is that nothing landed. *)
  let parse text =
    let line l =
      match String.split_on_char ' ' (String.trim l) with
        | [i; a; b] -> (
            match
              (int_of_string_opt i, int_of_string_opt a, int_of_string_opt b)
            with
              | Some i, Some a, Some b when i >= 0 && 0 <= a && a < b ->
                  Some (i, (a, b))
              | _ -> None)
        | _ -> None
    in
    let rec go acc = function
      | [] -> List.rev acc
      | "" :: rest -> go acc rest
      | l :: rest -> (
          match line l with Some e -> go (e :: acc) rest | None -> [])
    in
    go [] (String.split_on_char '\n' text)

  (* The one range to ask for so that [want] is held afterwards, or [None] when
     it already is. Always contiguous: where the two intervals leave a hole the
     hole comes too, and where [want] surrounds what is held the middle is
     fetched again rather than split into a request either side. *)
  let missing ~have ~want =
    let c, d = want in
    match have with
      | None -> Some want
      | Some (a, b) ->
          if c >= a && d <= b then None
          else if d <= a then Some (c, a)
          else if c >= b then Some (b, d)
          else if c < a && d > b then Some (c, d)
          else if c < a then Some (c, a)
          else Some (b, d)

  let widen ~have ~want =
    let c, d = want in
    match have with None -> want | Some (a, b) -> (min a c, max b d)
end

module Make
    (Io : Io.S)
    (Fs : FS with type 'a io := 'a Io.t)
    (Retry : SYSCALLS with type 'a io := 'a Io.t)
    (Bounded : POOLS with type 'a io := 'a Io.t)
    (C : Conf.S with type 'a io = 'a Io.t)
    (F : Fetch with type 'a io := 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x
  let return_unit = Io.return ()
  let return_some x = Io.return (Some x)
  let return_true = Io.return true
  let return_false = Io.return false

  let rec iter_s f = function
    | [] -> return_unit
    | x :: rest -> Io.bind (f x) (fun () -> iter_s f rest)

  let path group =
    Cache_layout.chunk_path ~cache_root:C.cache_root ~domain_name:C.domain_name
      (Manifest.Group.key group)

  let manifest_path group =
    Cache_layout.chunk_manifest_path ~cache_root:C.cache_root
      ~domain_name:C.domain_name (Manifest.Group.key group)

  let partial group = Retry.file_exists (manifest_path group)

  (* A body with no manifest beside it is whole, which is what every caller of
     this has always been told and what the atomic write still establishes. *)
  let exists group =
    let* here = Retry.file_exists (path group) in
    if not here then return_false
    else
      let+ incomplete = partial group in
      not incomplete

  let load_filled group =
    let+ text = Fs.read_file_opt (manifest_path group) in
    match text with None -> Filled.empty | Some text -> Filled.parse text

  let save_filled group filled =
    Fs.atomic_write (manifest_path group) (Filled.render filled)

  let full_member group filled i =
    Filled.interval filled i = Some (0, Manifest.Group.size group i)

  let whole group filled =
    List.for_all (full_member group filled) (Manifest.Group.indices group)

  (* Keyed by content, so two readers of one group share a fetch whether or not
     they are reading the same file.

     Owner and joiners share one record, so a reader that only waited on someone
     else's fetch is told the group came from a backend too -- which is what it
     was held up by. *)
  type inflight = { mutable done_ : unit Io.t; mutable from_backend : bool }

  let fetching : (string, inflight) Hashtbl.t = Hashtbl.create 64
  let in_flight () = Hashtbl.length fetching

  (* A member disagreeing with the manifest fails the write rather than reaching
     a caller as file content, wherever it was going to land. *)
  let sized group i data =
    let expected = Manifest.Group.size group i in
    if Bigstring.length data <> expected then
      Io.fail
        (Backend.Backend_error
           (Printf.sprintf "chunk %s: have %d bytes, manifest says %d"
              (Manifest.Group.member_key group i)
              (Bigstring.length data) expected))
    else return_unit

  (* The file is sized up front and each member written at its own offset, so
     members are produced concurrently and land in any order: a cold group costs
     about one round trip whatever [cache_chunk_size] is.

     {!Fs.atomic_write_at} requires every byte covered exactly once, which
     the length check enforces: a member disagreeing with the manifest fails the
     write rather than reaching a caller as file content. *)
  let write_group group body =
    let p = path group in
    let* () = Fs.ensure_parent p in
    (* Atomic, so presence alone proves a complete body. *)
    Fs.atomic_write_at p ~size:(Manifest.Group.bytes group) (fun put ->
        Io.iter_p
          (fun i ->
            let* data = body i in
            let* () = sized group i data in
            put ~offset:(Manifest.Group.offset group i) data)
          (Manifest.Group.indices group))

  (* Bounds fetches that have started, not groups asked for: a fetch opens its
     destination before waiting for a download slot, so without this every
     pending group holds a descriptor while only [max_downloads] make progress —
     247 open files inside 200ms on a 250 MB file at a 1 MiB group size, against
     a 256 descriptor limit.

     Bounded here rather than at the callers so every route in gets it. *)
  let slots = Bounded.create ~max:C.max_downloads ()

  let member group i = F.get_chunk ~chunk_key:(Manifest.Group.member_key group i)

  (* Fills what a partly filled body is missing, in place. The members it
     already holds whole are the ones a reader paid for, and fetching them again
     would undo exactly what those reads bought.

     Dropping the manifest last is what publishes the body: until then a reader
     sees a partial one, and every byte it claims is on disk. *)
  let complete_body group =
    let* filled = load_filled group in
    let owed =
      List.filter
        (fun i -> not (full_member group filled i))
        (Manifest.Group.indices group)
    in
    let* () =
      Io.iter_p
        (fun i ->
          let* data = member group i in
          let* () = sized group i data in
          let+ (_ : int) =
            Fs.write (path group) data
              ~offset:(Int64.of_int (Manifest.Group.offset group i))
          in
          ())
        owed
    in
    Fs.unlink_quiet (manifest_path group)

  let fetch group =
    Bounded.use slots (fun () ->
        let* partial = Retry.file_exists (path group) in
        if partial then complete_body group
        else
          let* () = write_group group (member group) in
          (* A manifest left behind by a body the cap took describes a body that
             is not there; the one just written is whole. *)
          Fs.unlink_quiet (manifest_path group))

  (* Concurrent callers await the same fetch; [force] re-fetches a body believed
     corrupt. Answers whether the body had to come from a backend. *)
  let ensure_fetched ?(force = false) ~group () =
    let key = Manifest.Group.key group in
    match Hashtbl.find_opt fetching key with
      | Some entry ->
          let+ () = entry.done_ in
          entry.from_backend
      | None ->
          let entry = { done_ = return_unit; from_backend = false } in
          (* Nothing below runs until this is woken, which is after the entry is
             in the table: a second caller must find it there rather than start
             a fetch of its own. *)
          let started, start = Io.wait () in
          let t =
            Io.finalize
              (fun () ->
                let* () = started in
                let* present = if force then return_false else exists group in
                if present then return_unit
                else (
                  (* Before [fetch], not inside it: the wait on [slots] is part
                     of what the network costs this reader. *)
                  entry.from_backend <- true;
                  fetch group))
              (fun () ->
                Hashtbl.remove fetching key;
                return_unit)
          in
          entry.done_ <- t;
          Hashtbl.replace fetching key entry;
          Io.wakeup_later start ();
          let+ () = t in
          entry.from_backend

  let ensure ?force ~group () =
    let+ _ = ensure_fetched ?force ~group () in
    ()

  (* The tail of a promotion, where every member is a local staged body.
     Idempotent: a body already under this key is the same bytes. *)
  let put_group ~group ~member =
    let* present = exists group in
    if present then return_unit
    else
      let* () = write_group group member in
      (* Whole by construction, whatever a partial body left here claimed. *)
      Fs.unlink_quiet (manifest_path group)

  (* Every chunk here is re-fetchable, so holding the store under [C.max_cache]
     needs no residency, open counts or dirty checks. *)

  let root () = Cache_layout.chunks_dir ~cache_root:C.cache_root C.domain_name

  (* One budget for the store, not per sweep: [stats] is answered per status
     request, so a per-call bound would limit each sweep and none of them
     together.

     Held around a stat only, the directory holding it being {!dir_slots}'s to
     bound: one pool across both levels deadlocks, every slot held by a
     directory whose entries are waiting for one. *)
  let metadata_slots = Bounded.create ~max:64 ()

  (* The shard directories, which is a caller-sized fan-out of its own: the
     cache is split {!Chunk_layout.shards} ways, and [readdir_list] holds an
     open directory and its whole name list. Its own pool rather than
     [metadata_slots], which the entries inside each directory take from —
     nesting one pool inside itself deadlocks. *)
  let dir_slots = Bounded.create ~max:16 ()

  (* (path, bytes, mtime) per chunk body. Stat'd in parallel: one at a time is a
     round trip each, milliseconds against seconds on a few thousand chunks. *)
  let entries () =
    let* dirs = Fs.readdir_list (root ()) in
    let+ per_dir =
      Bounded.map_with dir_slots
        (fun dir ->
          let dir = Filename.concat (root ()) dir in
          let* names = Fs.readdir_list dir in
          Bounded.filter_map_with metadata_slots
            (fun name ->
              (* A manifest is not a chunk body: counting one reports a store
                 holding more than it does, and evicting one on its own leaves a
                 partial body reading as a whole one. It goes where its body
                 goes. *)
              if Filename.check_suffix name Cache_layout.manifest_suffix then
                Io.return None
              else
                let path = Filename.concat dir name in
                Io.catch
                  (fun () ->
                    let+ st = Retry.stat path in
                    Some (path, st.Unix.st_size, st.Unix.st_mtime))
                  (fun _ -> Io.return None))
            names)
        dirs
    in
    List.concat per_dir

  let stats () =
    Io.catch
      (fun () ->
        let+ items = entries () in
        ( List.length items,
          List.fold_left (fun acc (_, bytes, _) -> acc + bytes) 0 items ))
      (fun _ -> Io.return (0, 0))

  (* Coldest first. Best-effort: a chunk deleted under an in-flight read is
     fetched again ({!body}). *)
  let enforce_cap () =
    match C.max_cache with
      | None -> return_unit
      | Some cap ->
          let* items = Io.catch entries (fun _ -> Io.return []) in
          let total =
            List.fold_left (fun acc (_, bytes, _) -> acc + bytes) 0 items
          in
          if total <= cap then return_unit
          else (
            let coldest =
              List.sort (fun (_, _, a) (_, _, b) -> compare a b) items
            in
            let rec go total = function
              | [] -> return_unit
              | _ when total <= cap -> return_unit
              | (path, bytes, _) :: rest ->
                  Log.debug "chunk cache: dropping %s (%d bytes)"
                    (Filename.basename path) bytes;
                  let* () = Fs.unlink_quiet path in
                  (* After the body, so a crash leaves a manifest describing a
                     body that is gone -- read as an empty group -- rather than a
                     partial body read as a whole one. *)
                  let* () =
                    Fs.unlink_quiet (path ^ Cache_layout.manifest_suffix)
                  in
                  go (total - bytes) rest
            in
            go total coldest)

  let forget ~group =
    let* () = Fs.unlink_quiet (path group) in
    Fs.unlink_quiet (manifest_path group)

  (* Adopt [src] as this group's body by giving the same bytes a second name.
     The cache owns where a group body lives, so the staged half hands over the
     file rather than the destination.

     Not every cache root can hold a second name for one inode -- some Android
     storage goes through a shim that cannot -- and the answer is the same for
     every group once it is known, so it is asked once and remembered. Errors
     that are per-inode or transient leave it unanswered. *)
  let links_supported = ref None

  let link_in ~src ~group =
    if !links_supported = Some false then return_false
    else (
      let dst = path group in
      Io.catch
        (fun () ->
          let* () = Fs.ensure_parent dst in
          (* A partly filled body under this name would take the link's place
             and be published as the group: the name existing is proof of whole
             bytes only while no manifest sits beside it. *)
          let* incomplete = partial group in
          let* () =
            if not incomplete then return_unit
            else
              let* () = Fs.unlink_quiet dst in
              Fs.unlink_quiet (manifest_path group)
          in
          let* () = Retry.link src dst in
          let now = Unix.gettimeofday () in
          (* Dated now, or the cap reads a freshly published group as being as
             old as the write that staged it. *)
          let+ () =
            Io.catch (fun () -> Retry.utimes dst now now) (fun _ -> return_unit)
          in
          links_supported := Some true;
          true)
        (function
          | Unix.Unix_error (Unix.EEXIST, _, _) ->
              links_supported := Some true;
              return_true
          | Unix.Unix_error
              ((Unix.EPERM | Unix.ENOSYS | Unix.EOPNOTSUPP | Unix.EXDEV), _, _)
            as exn ->
              Log.info "chunk cache: publishing by link unavailable (%s)"
                (Printexc.to_string exn);
              links_supported := Some false;
              return_false
          | _ -> return_false))

  (* Puts [want] of stored chunk [index] on disk, fetching only what the body is
     missing, and answers what crossed the wire.

     The manifest goes down before the first byte it will describe, and is
     extended only once those bytes have landed. Both orders are the same
     choice: what survives a crash claims less than the disk holds, and being
     wrong that way costs a re-fetch. The other way round leaves a partial body
     with no manifest, which every reader takes for a whole one. *)
  let fill group ~index ~want =
    let* here = Retry.file_exists (path group) in
    (* A manifest whose body the cap took describes nothing, so the group starts
       again rather than trusting it. *)
    let* filled = if here then load_filled group else Io.return Filled.empty in
    match Filled.missing ~have:(Filled.interval filled index) ~want with
      | None -> Io.return 0
      | Some (lo, hi) ->
          let* () =
            if here then return_unit
            else
              let* () = Fs.ensure_parent (path group) in
              save_filled group Filled.empty
          in
          let* data =
            F.get_chunk_range
              ~chunk_key:(Manifest.Group.member_key group index)
              ~offset:lo ~length:(hi - lo)
          in
          let got = Bigstring.length data in
          if got = 0 then Io.return 0
          else
            let* (_ : int) =
              Fs.write (path group) data
                ~offset:(Int64.of_int (Manifest.Group.offset group index + lo))
            in
            let span =
              Filled.widen ~have:(Filled.interval filled index)
                ~want:(lo, lo + got)
            in
            let filled = Filled.put filled index span in
            let+ () =
              if whole group filled then Fs.unlink_quiet (manifest_path group)
              else save_filled group filled
            in
            got

  (* The cap may delete a group between the fetch and the read, or mid-read, so a
     miss or short read is retried once against a freshly fetched body. A second
     failure is real and raised. *)
  let read_into ~group ~index buf ~chunk_off =
    let want = Bigarray.Array1.dim buf in
    let offset = Int64.of_int (Manifest.Group.offset group index + chunk_off) in
    let attempt () = Fs.read (path group) buf ~offset in
    (* A refetch went to a backend by construction, whatever the first [ensure]
       answered. *)
    let refetch () =
      let* _ = ensure_fetched ~force:true ~group () in
      let+ n = attempt () in
      { bytes = n; fetched = Manifest.Group.bytes group; from_backend = true }
    in
    let read_or_refetch ~fetched ~from_backend =
      Io.catch
        (fun () ->
          let* n = attempt () in
          if n = want then Io.return { bytes = n; fetched; from_backend }
          else refetch ())
        (function
          | Unix.Unix_error (Unix.ENOENT, _, _) -> refetch ()
          | exn -> Io.fail exn)
    in
    let* complete = exists group in
    if complete then read_or_refetch ~fetched:0 ~from_backend:false
    else
      match Hashtbl.find_opt fetching (Manifest.Group.key group) with
        (* The whole group is already on its way: waiting for it costs this
           reader nothing a range would have saved, and leaves one writer on the
           body. *)
        | Some entry ->
            let* () = entry.done_ in
            read_or_refetch ~fetched:0 ~from_backend:entry.from_backend
        | None ->
            let upto =
              min (chunk_off + want) (Manifest.Group.size group index)
            in
            let* fetched = fill group ~index ~want:(chunk_off, upto) in
            read_or_refetch ~fetched ~from_backend:(fetched > 0)
end
