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
end

(* What a read cost. Hoisted out of [Make]: it describes a read, not one
   store's state, and the staged half names it too. *)
type served = { bytes : int; from_backend : bool }

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

  let exists group = Retry.file_exists (path group)

  (* Keyed by content, so two readers of one group share a fetch whether or not
     they are reading the same file.

     Owner and joiners share one record, so a reader that only waited on someone
     else's fetch is told the group came from a backend too -- which is what it
     was held up by. *)
  type inflight = { mutable done_ : unit Io.t; mutable from_backend : bool }

  let fetching : (string, inflight) Hashtbl.t = Hashtbl.create 64
  let in_flight () = Hashtbl.length fetching

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
            let expected = Manifest.Group.size group i in
            if Bigstring.length data <> expected then
              Io.fail
                (Backend.Backend_error
                   (Printf.sprintf "chunk %s: have %d bytes, manifest says %d"
                      (Manifest.Group.member_key group i)
                      (Bigstring.length data) expected))
            else put ~offset:(Manifest.Group.offset group i) data)
          (Manifest.Group.indices group))

  (* Bounds fetches that have started, not groups asked for: a fetch opens its
     destination before waiting for a download slot, so without this every
     pending group holds a descriptor while only [max_downloads] make progress —
     247 open files inside 200ms on a 250 MB file at a 1 MiB group size, against
     a 256 descriptor limit.

     Bounded here rather than at the callers so every route in gets it. *)
  let slots = Bounded.create ~max:C.max_downloads ()

  let fetch group =
    Bounded.use slots (fun () ->
        write_group group (fun i ->
            F.get_chunk ~chunk_key:(Manifest.Group.member_key group i)))

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
    if present then return_unit else write_group group member

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
                  go (total - bytes) rest
            in
            go total coldest)

  let forget ~group = Fs.unlink_quiet (path group)

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
      { bytes = n; from_backend = true }
    in
    let* from_backend = ensure_fetched ~group () in
    Io.catch
      (fun () ->
        let* n = attempt () in
        if n = want then Io.return { bytes = n; from_backend } else refetch ())
      (function
        | Unix.Unix_error (Unix.ENOENT, _, _) -> refetch () | exn -> Io.fail exn)
end
