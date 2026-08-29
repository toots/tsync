(* File content as bytes, served per cache chunk out of {!Chunk_cache}.

   A file is never assembled: a read maps its byte range onto the stored chunks
   backing it and fetches what is absent, the store answering "is it local?" by
   the body existing. *)

(* Read-ahead applies to sequential reads only. *)
(* What this needs below it. *)
module type FS = sig
  type 'a io
  type fd

  val zero : Bigstring.t -> pos:int -> len:int -> unit
  val pread : fd -> Bigstring.t -> file_offset:int -> int -> int -> int io
  val read : string -> Bigstring.t -> offset:int64 -> int io
  val write : string -> Bigstring.t -> offset:int64 -> int io
  val copy_file : src:string -> dst:string -> unit io
  val ensure_parent : string -> unit io
  val is_directory : string -> bool io
  val readdir_list : string -> string list io
  val read_file_opt : string -> string option io
  val atomic_write : string -> string -> unit io
  val reap_older_than : cutoff:float -> string -> bool io
  val unlink_quiet : string -> unit io

  val atomic_write_at :
    string ->
    size:int ->
    ((offset:int -> Bigstring.t -> unit io) -> unit io) ->
    unit io

  val real_dir_name : string -> string -> string io
end

module type SYSCALLS = sig
  type 'a io
  type fd

  val file_exists : string -> bool io
  val stat : string -> Unix.stats io
  val link : string -> string -> unit io
  val rename : string -> string -> unit io
  val utimes : string -> float -> float -> unit io
  val openfile : string -> Unix.open_flag list -> Unix.file_perm -> fd io
  val close : fd -> unit io

  module LargeFile : sig
    val stat : string -> Unix.LargeFile.stats io
    val ftruncate : fd -> int64 -> unit io
  end
end

module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val use : t -> (unit -> 'a io) -> 'a io
  val map_with : t -> ('a -> 'b io) -> 'a list -> 'b list io
  val iter_with : t -> ('a -> unit io) -> 'a list -> unit io
  val filter_map_with : t -> ('a -> 'b option io) -> 'a list -> 'b list io
end

module type LOCKS = sig
  type 'a io
  type mutex

  val mutex : unit -> mutex
  val with_lock : mutex -> (unit -> 'a io) -> 'a io
end

module type MIRROR = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val published : Logical_key.t -> Manifest.t option io
    val write : Logical_key.t -> Manifest.t -> unit io

    val current :
      Logical_key.t ->
      [ `Staged of Staged_manifest.staged * Manifest.t option
      | `Published of Manifest.t ]
      option
      io
  end
end

(* What this needs of the store above it. *)
module type REMOTE = sig
  type 'a io

  val chunk_size : unit -> int io
  val get_chunk : chunk_key:string -> Bigstring.t io

  val get_chunk_range :
    chunk_key:string -> offset:int -> length:int -> Bigstring.t io

  val upload :
    key:Logical_key.t ->
    src_path:string ->
    mtime:float ->
    chunk_size:int ->
    ?cancel:bool ref ->
    ?on_progress:(bytes:int -> sent:bool -> unit) ->
    unit ->
    Manifest.t io

  val upload_chunks :
    key:Logical_key.t ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:(int -> unit io Chunk_source.t io) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.t io

  val fetch_manifest : key:Logical_key.t -> unit -> Manifest.t option io
end

module Over
    (Io : Io.S)
    (Fs : FS with type 'a io := 'a Io.t)
    (Retry : SYSCALLS with type 'a io := 'a Io.t and type fd = Fs.fd)
    (Lock : LOCKS with type 'a io := 'a Io.t)
    (Bounded : POOLS with type 'a io := 'a Io.t)
    (Mf : MIRROR with type 'a io := 'a Io.t) =
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

  let rec fold_left_s f acc = function
    | [] -> Io.return acc
    | x :: rest -> Io.bind (f acc x) (fun acc -> fold_left_s f acc rest)

  let readahead_bytes = 4 * 1024 * 1024
  let max_readahead_groups = 8

  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (R : REMOTE with type 'a io := 'a Io.t) =
  struct
    module Cc = Chunk_cache.Make (Io) (Fs) (Retry) (Bounded) (C) (R)
    module Bodies = Staged_body.Over (Io) (Fs) (Retry)
    module Sb = Bodies.Make (C) (Cc)
    module Mf = Mf.Make (C)
    module Staged = Staged_manifest.Over (Io) (Fs) (Retry)
    module Mfs = Staged.Make (C)

    (* Keyed by the reading stream rather than by the file: two descriptors open
       on one file each walk it at their own pace, and a shared position reads
       each one's progress as the other's and prefetches for neither.

       Advisory: a lost or stale entry costs at most one un-prefetched read. *)
    let last_read_end : (string, int) Hashtbl.t = Hashtbl.create 64

    (* Files waiting on the network because something is reading them. Separate
       from [active] below, which tracks whole-file materialization: that has a
       total known up front and a scoped lifetime, and a demand read has neither.

       A materialization's reads do not land here on their own: it fetches every
       group first, so by the time [pread] runs the chunks are local and report no
       backend. {!fetch_groups} credits it instead, at the one point where it does
       touch the network -- otherwise a fetch started from Finder, which is the
       whole of what the macOS frontend does, shows in the tray as a count with no
       rows under it. *)
    type pull = {
      size : int;
      started : float;
      mutable bytes : int;
      mutable last : float;
      (* Measured over a window rather than since the start, so a stall shows as
         the rate falling rather than as an average that takes as long to decay as
         it took to build. *)
      mutable mark_at : float;
      mutable mark_bytes : int;
      mutable rate : float;
    }

    let rate_window = 2.
    let pulls : (string, pull) Hashtbl.t = Hashtbl.create 8

    (* Longer than the tray's poll interval, or a row blinks out between two polls
       that both saw traffic. *)
    let pull_idle = 8.

    (* A cold `grep -r' over a large tree touches every file in it. Without a cap
       the table grows for the life of the process whether or not anyone is
       watching. *)
    let max_pulling = 256

    let prune_pulls now =
      Hashtbl.filter_map_inplace
        (fun _ p ->
          let idle = now -. p.last in
          (* A negative idle is the clock having stepped, not a fresh entry.
             Expiring it beats letting a row sit there until the daemon restarts. *)
          if idle > pull_idle || idle < 0. then None else Some p)
        pulls

    (* Synchronous, and called with no await between the lookup and the update:
       every writer runs on the one loop, a worker with a thread of its own
       reaching it by handing the work back, so that is all the mutual exclusion
       this needs. *)
    let credit_pull key ~size n =
      let now = Unix.gettimeofday () in
      match Hashtbl.find_opt pulls key with
        | Some p ->
            p.bytes <- p.bytes + n;
            p.last <- now;
            let elapsed = now -. p.mark_at in
            if elapsed >= rate_window then (
              p.rate <- float_of_int (p.bytes - p.mark_bytes) /. elapsed;
              p.mark_at <- now;
              p.mark_bytes <- p.bytes)
        | None ->
            if Hashtbl.length pulls >= max_pulling then prune_pulls now;
            Hashtbl.replace pulls key
              {
                size;
                started = now;
                bytes = n;
                last = now;
                mark_at = now;
                mark_bytes = 0;
                rate = 0.;
              }

    type pulling = {
      key : string;
      bytes : int;
      size : int;
      seconds : float;
      rate : float;
    }

    (* [status] asks on every tray poll, so the answer is bounded. Biggest first,
       so what is cut is what mattered least. *)
    let max_reported = 16

    let pulling_now ?now () =
      let now = match now with Some t -> t | None -> Unix.gettimeofday () in
      prune_pulls now;
      Hashtbl.fold
        (fun key (p : pull) acc ->
          {
            key;
            bytes = p.bytes;
            size = p.size;
            (* Guarded for the same clock step [prune_pulls] guards against. *)
            seconds = Float.max 0. (now -. p.started);
            (* Nothing measured yet, so the average stands in rather than a zero
               that would read as a stall. *)
            rate =
              (if p.rate > 0. then p.rate
               else (
                 let elapsed = Float.max 0. (now -. p.started) in
                 if elapsed > 0. then float_of_int p.bytes /. elapsed else 0.));
          }
          :: acc)
        pulls []
      |> List.sort (fun a b -> compare b.bytes a.bytes)
      |> List.filteri (fun i _ -> i < max_reported)

    let cache_chunk_size = Conf.cache_chunk_size (module C)

    (* From the file's own chunk size, so one uploaded under a different setting
       still groups the way its own body says. *)
    let per_of m =
      Conf.chunks_per_group ~chunk_size:(Manifest.chunk_size m)
        ~cache_chunk_size

    let groups m = Manifest.Group.all ~table:m ~per:(per_of m)

    (* The staged path inherits from a published manifest that may not exist. *)
    let group_at_opt base i =
      match base with
        | None -> None
        | Some m -> Manifest.Group.of_table ~table:m ~per:(per_of m) i

    (* Reuses [cached] while [i] stays in the same group, so a sequential read
       rebuilds one group per boundary crossing rather than one per chunk. *)
    let group_at ~table ~per ~cached i =
      let gi = Manifest.Group.index_of ~per i in
      match cached with
        | Some (j, g) when j = gi -> Some (gi, g)
        | _ ->
            Option.map
              (fun g -> (gi, g))
              (Manifest.Group.of_table ~table ~per i)

    (* Credits {!pulls} as a foreground read does: prefetch is what pulls the bytes
       during sequential streaming, so leaving it out would empty the display
       exactly when a large file is downloading well. *)
    (* One loop per sequential read, and a FUSE read is 128 KiB, so streaming a
       gigabyte fires thousands of these. They are mostly redundant —
       {!Chunk_cache.ensure_fetched} hands a second caller the in-flight promise —
       but the spawn rate is the reader's, not ours, so the count in flight is
       ours to hold down. *)
    let readahead_in_flight = ref 0
    let max_readahead_loops = 4

    let read_ahead ~id ~size ~table ~per ~chunk_size ~last =
      let n = Manifest.count table in
      let window =
        min max_readahead_groups
          (max 1 (readahead_bytes / max 1 (per * max 1 chunk_size)))
      in
      let first = (Manifest.Group.index_of ~per last + 1) * per in
      let hi = min (n - 1) (first + (window * per) - 1) in
      if first <= hi && !readahead_in_flight < max_readahead_loops then (
        incr readahead_in_flight;
        Io.async (fun () ->
            Io.finalize
              (fun () ->
                Io.catch
                  (fun () ->
                    let rec go i =
                      if i > hi then return_unit
                      else
                        let* () =
                          match Manifest.Group.of_table ~table ~per i with
                            | Some group ->
                                let+ fetched = Cc.ensure_fetched ~group () in
                                if fetched then
                                  credit_pull id ~size
                                    (Manifest.Group.bytes group)
                            | None -> return_unit
                        in
                        go (i + per)
                    in
                    go first)
                  (fun _ -> return_unit))
              (fun () ->
                decr readahead_in_flight;
                return_unit)))

    (* [id] names the file for the read-ahead heuristic and for {!pulling}, which
       is how a byte fetched here is attributed to the file someone is reading. *)
    let pread ~id ?stream ~(manifest : Manifest.t) buf ~offset =
      let stream = Option.value stream ~default:id in
      let cs = Manifest.chunk_size manifest in
      let size = Manifest.size manifest in
      let want = Bigarray.Array1.dim buf in
      let start = Int64.to_int offset in
      let avail = Int64.to_int (Int64.sub size offset) in
      let total = min want (max 0 avail) in
      let table = manifest in
      let n = Manifest.count table in
      if total <= 0 || cs <= 0 || n = 0 then Io.return 0
      else (
        let per = per_of manifest in
        let rec go pos done_ cached =
          if done_ >= total then Io.return done_
          else (
            let i = Chunks.index_of ~chunk_size:cs pos in
            if i >= n then Io.return done_
            else (
              let chunk_off = pos mod cs in
              let take = min (cs - chunk_off) (total - done_) in
              match group_at ~table ~per ~cached i with
                | None ->
                    Io.fail
                      (Backend.Backend_error
                         (Printf.sprintf "manifest %s: missing chunk %d" id i))
                | Some (_, group) as cached ->
                    let slice = Bigarray.Array1.sub buf done_ take in
                    let* served =
                      Cc.read_into ~group ~index:i slice ~chunk_off
                    in
                    let got = served.Chunk_cache.bytes in
                    (* What crossed the wire, which is neither the slice nor the
                       group: a read may pull a range of one stored chunk, a
                       whole group, or nothing. *)
                    if served.Chunk_cache.fetched > 0 then
                      credit_pull id ~size:(Int64.to_int size)
                        served.Chunk_cache.fetched;
                    if got <= 0 then Io.return done_
                    else go (pos + got) (done_ + got) cached))
        in
        let* got = go start 0 None in
        let last =
          min (n - 1) (Chunks.index_of ~chunk_size:cs (start + max 0 (got - 1)))
        in
        if Hashtbl.find_opt last_read_end stream = Some start then
          read_ahead ~id ~size:(Int64.to_int size) ~table ~per ~chunk_size:cs
            ~last;
        Hashtbl.replace last_read_end stream (start + got);
        Io.return got)

    let rec pread_staged ~id ~(staged : Staged_manifest.staged) ~base buf
        ~offset =
      match staged.Staged_manifest.s_whole with
        | Some uuid ->
            let want = Bigarray.Array1.dim buf in
            let avail =
              Int64.to_int (Int64.sub staged.Staged_manifest.s_size offset)
            in
            let total = min want (max 0 avail) in
            if total <= 0 then Io.return 0
            else
              Sb.whole_read_into ~uuid (Bigarray.Array1.sub buf 0 total) ~offset
        | None -> pread_chunked ~id ~staged ~base buf ~offset

    and pread_chunked ~id ~(staged : Staged_manifest.staged) ~base buf ~offset =
      let cs = staged.Staged_manifest.s_chunk_size in
      let want = Bigarray.Array1.dim buf in
      let start = Int64.to_int offset in
      let avail =
        Int64.to_int (Int64.sub staged.Staged_manifest.s_size offset)
      in
      let total = min want (max 0 avail) in
      if total <= 0 || cs <= 0 then Io.return 0
      else (
        let slots = staged.Staged_manifest.s_slots in
        let n = Array.length slots in

        let rec go pos done_ =
          if done_ >= total then Io.return done_
          else (
            let i = Chunks.index_of ~chunk_size:cs pos in
            if i >= n then Io.return done_
            else (
              let chunk_off = pos mod cs in
              let take = min (cs - chunk_off) (total - done_) in
              let slice = Bigarray.Array1.sub buf done_ take in
              let* got =
                match slots.(i) with
                  | Staged_manifest.Staged { uuid; offset = body_off } ->
                      let* got =
                        Sb.read_into ~uuid slice ~offset:(body_off + chunk_off)
                      in
                      (* A staged body is only as long as the writes that reached
                         it: past its end is a hole, reading as zeros. *)
                      if got < take then (
                        Bigarray.Array1.fill
                          (Bigarray.Array1.sub slice got (take - got))
                          '\000';
                        Io.return take)
                      else Io.return got
                  | Staged_manifest.Zero ->
                      Bigarray.Array1.fill slice '\000';
                      Io.return take
                  | Staged_manifest.Inherit -> (
                      match group_at_opt base i with
                        | Some group ->
                            let+ served =
                              Cc.read_into ~group ~index:i slice ~chunk_off
                            in
                            if served.Chunk_cache.fetched > 0 then
                              credit_pull id
                                ~size:
                                  (Int64.to_int staged.Staged_manifest.s_size)
                                served.Chunk_cache.fetched;
                            served.Chunk_cache.bytes
                        | None ->
                            Io.fail
                              (Backend.Backend_error
                                 (Printf.sprintf
                                    "staged %s: chunk %d inherits nothing" id i))
                      )
              in
              if got <= 0 then Io.return done_ else go (pos + got) (done_ + got)))
        in
        go start 0)

    (* The mirror is the whole answer: a key reaches it by the poller replaying
       what a peer published, so a name it does not hold is a name the domain
       does not have as of the journal this client has applied. *)
    let published key = Mf.published key

    (* A promotion can retire the staged bodies between resolving the key and
       reading them, so a miss is resolved again and read once more. The retry
       finds the published manifest because {!promote} puts it in place before any
       body goes, the same shape as {!Chunk_cache.read_into} against the cap. *)
    (* [stream] names the descriptor asking, for callers that have one; without
       it every reader of a key shares its position. *)
    let pread_key ?stream key buf ~offset =
      let id = Logical_key.to_string key in
      let stream =
        match stream with None -> id | Some s -> id ^ "\000" ^ s
      in
      let attempt () =
        let* resolved = Mf.current key in
        match resolved with
          | Some (`Staged (staged, base)) ->
              pread_staged ~id ~staged ~base buf ~offset
          | Some (`Published m) -> pread ~id ~stream ~manifest:m buf ~offset
          | None -> Io.return 0
      in
      Io.catch attempt (function
        | Unix.Unix_error (Unix.ENOENT, _, _) -> attempt ()
        | exn -> Io.fail exn)

    (* One mutation of a key at a time. Promotion hands a staged body to the chunk
       store under its content name, so a write arriving partway through would
       change bytes the upload has already hashed and published.

       Reads stay outside it: verifying a large file holds the key for as long as
       the read takes, which is exactly the caller a promotion must not wait for. *)
    let key_locks : (string, Lock.mutex * int ref) Hashtbl.t = Hashtbl.create 16

    let with_key key f =
      let key = Logical_key.to_string key in
      let entry =
        match Hashtbl.find_opt key_locks key with
          | Some entry -> entry
          | None ->
              let entry = (Lock.mutex (), ref 0) in
              Hashtbl.replace key_locks key entry;
              entry
      in
      let mutex, holders = entry in
      incr holders;
      Io.finalize
        (fun () -> Lock.with_lock mutex f)
        (fun () ->
          decr holders;
          if !holders = 0 then Hashtbl.remove key_locks key;
          return_unit)

    (* Where each member of a group sits in the body that holds it: the running
       sum of the lengths before it, which is what {!Manifest.Group.offset} computes
       for the published group these bytes become. *)
    let group_layout ~(st : Staged_manifest.staged) ~first ~last =
      let len j =
        Chunks.length_of ~size:st.Staged_manifest.s_size
          ~chunk_size:st.Staged_manifest.s_chunk_size j
      in
      let rec go j offset acc =
        if j > last then (List.rev acc, offset)
        else go (j + 1) (offset + len j) ((j, offset, len j) :: acc)
      in
      go first 0 []

    (* A whole body is split into chunks first: only chunks can be addressed by a
       partial write. *)
    let rec staged_for key =
      let* st = Mfs.read_edits key in
      match st with
        | Some ({ Staged_manifest.s_whole = Some uuid; _ } as st) ->
            let* () = split_whole key st uuid in
            staged_for key
        | Some st -> Io.return st
        | None -> (
            let* chunk_size = R.chunk_size () in
            let+ published = Mf.published key in
            let name = Logical_key.leaf key in
            match published with
              | Some m ->
                  {
                    (* The key names this file; the published body names whatever
                       it was filed as. *)
                    Staged_manifest.s_name = name;
                    s_size = Manifest.size m;
                    s_mtime = Unix.gettimeofday ();
                    s_chunk_size = Manifest.chunk_size m;
                    s_slots =
                      Array.make
                        (Chunks.count ~size:(Manifest.size m)
                           ~chunk_size:(Manifest.chunk_size m))
                        Staged_manifest.Inherit;
                    s_whole = None;
                  }
              | None ->
                  {
                    Staged_manifest.s_name = name;
                    s_size = 0L;
                    s_mtime = Unix.gettimeofday ();
                    s_chunk_size = chunk_size;
                    s_slots = [||];
                    s_whole = None;
                  })

    and split_whole key (st : Staged_manifest.staged) uuid =
      let* cs = R.chunk_size () in
      let n = Chunks.count ~size:st.Staged_manifest.s_size ~chunk_size:cs in
      let slots = Array.make n Staged_manifest.Zero in
      let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout cs in
      let per = Conf.chunks_per_group ~chunk_size:cs ~cache_chunk_size in
      let st_for_layout = { st with Staged_manifest.s_chunk_size = cs } in
      let rec chunk i body offset =
        if i >= n then return_unit
        else
          let* body, offset =
            if Manifest.Group.index_of ~per i * per = i then (
              let body = Staged_manifest.new_uuid () in
              let last = min (n - 1) (i + per - 1) in
              let _, body_len = group_layout ~st:st_for_layout ~first:i ~last in
              let+ () = Sb.ensure ~uuid:body ~len:body_len in
              (body, 0))
            else Io.return (body, offset)
          in
          let len =
            Chunks.length_of ~size:st.Staged_manifest.s_size ~chunk_size:cs i
          in
          let slice = Bigarray.Array1.sub buf 0 len in
          let* (_ : int) =
            Sb.whole_read_into ~uuid slice
              ~offset:(Int64.of_int (Chunks.offset_of ~chunk_size:cs i))
          in
          let* (_ : int) = Sb.write ~uuid:body slice ~offset in
          slots.(i) <- Staged_manifest.Staged { uuid = body; offset };
          chunk (i + 1) body (offset + len)
      in
      let* () = chunk 0 "" 0 in
      let st =
        {
          st with
          Staged_manifest.s_slots = slots;
          s_chunk_size = cs;
          s_whole = None;
        }
      in
      let* () = Mfs.write key st in
      Sb.whole_forget ~uuid

    (* Writing the result of this back is what retires a finished upload: the
       record it published describes bytes that just changed. *)
    let mutated (st : Staged_manifest.staged) =
      { st with Staged_manifest.s_mtime = Unix.gettimeofday () }

    let grow_slots slots n =
      let old = Array.length slots in
      if n <= old then slots
      else (
        let a = Array.make n Staged_manifest.Zero in
        Array.blit slots 0 a 0 old;
        a)

    (* The body a group's staged members share, when they share one: the same
       uuid, each at the offset [members] says it belongs at. [Zero] members are
       skipped, since a hole is whatever the body already holds there. *)
    let shared_body ~slot_at members =
      List.fold_left
        (fun acc (j, offset) ->
          match (acc, slot_at j) with
            | `No, _ -> `No
            | acc, Staged_manifest.Zero -> acc
            | `Unset, Staged_manifest.Staged b
              when b.Staged_manifest.offset = offset ->
                `Body b.Staged_manifest.uuid
            | `Body u, Staged_manifest.Staged b
              when b.Staged_manifest.uuid = u
                   && b.Staged_manifest.offset = offset ->
                `Body u
            | _ -> `No)
        `Unset members
      |> function
      | `Body uuid -> Some uuid
      | `Unset | `No -> None

    (* Establishes that every staged member of the group [i] falls in shares one
       body and sits at its layout offset, so the body is the group's bytes
       already assembled and publishing it is a link rather than a copy.

       The whole group is staged, never part of it: the group's key covers all its
       members, so a body holding only some of them could not be published under
       the key the others still name. *)
    let ensure_group_body ~base ~(st : Staged_manifest.staged) ~covers i =
      let slots = st.Staged_manifest.s_slots in
      let per =
        Conf.chunks_per_group ~chunk_size:st.Staged_manifest.s_chunk_size
          ~cache_chunk_size
      in
      let n = Array.length slots in
      let first = Manifest.Group.index_of ~per i * per in
      let last = min (n - 1) (first + per - 1) in
      let members, body_len = group_layout ~st ~first ~last in

      (* Already one body at the right offsets, which is a second write to a group
         it has staged before: no copy. *)
      let shared =
        shared_body
          ~slot_at:(fun j -> slots.(j))
          (List.map (fun (j, offset, _) -> (j, offset)) members)
      in
      match shared with
        | Some uuid ->
            let+ () = Sb.ensure ~uuid ~len:body_len in
            (* Every hole in the group becomes part of the body, covered by this
               write or not: the body is sparse there, which is the same bytes a
               hole reads as, and a member left behind is one the write is about
               to be told it cannot address. *)
            List.iter
              (fun (j, offset, _) ->
                match slots.(j) with
                  | Staged_manifest.Zero ->
                      slots.(j) <- Staged_manifest.Staged { uuid; offset }
                  | Staged_manifest.Staged _ | Staged_manifest.Inherit -> ())
              members
        | None ->
            let uuid = Staged_manifest.new_uuid () in
            let stale = Staged_manifest.body_uuids slots in
            let* () = Sb.ensure ~uuid ~len:body_len in
            let* () =
              iter_s
                (fun (j, offset, len) ->
                  (* A member the write is about to replace whole needs nothing
                     read in. *)
                  if covers j then return_unit
                  else (
                    match slots.(j) with
                      | Staged_manifest.Staged b ->
                          Sb.copy ~src:b.Staged_manifest.uuid
                            ~src_off:b.Staged_manifest.offset ~dst:uuid
                            ~dst_off:offset ~len
                      | Staged_manifest.Inherit -> (
                          match group_at_opt base j with
                            | Some group ->
                                Sb.copy_chunk ~group ~index:j ~uuid ~offset
                            (* Nothing published to inherit: a hole, and the body
                               is already sparse there. *)
                            | None -> return_unit)
                      | Staged_manifest.Zero -> return_unit))
                members
            in
            List.iter
              (fun (j, offset, _) ->
                slots.(j) <- Staged_manifest.Staged { uuid; offset })
              members;
            let live = Staged_manifest.body_uuids slots in
            iter_s
              (fun old ->
                if List.mem old live then return_unit else Sb.forget ~uuid:old)
              stale

    (* Bytes land before the staged manifest: a crash in between leaves an
       unreferenced body rather than a manifest pointing at unwritten bytes. *)
    let write_locked key buf ~offset =
      let len = Bigarray.Array1.dim buf in
      let* st = staged_for key in
      let* base = Mf.published key in
      let cs = st.Staged_manifest.s_chunk_size in
      let start = Int64.to_int offset in
      let new_size =
        Int64.of_int
          (max (Int64.to_int st.Staged_manifest.s_size) (start + len))
      in
      let slots =
        grow_slots st.Staged_manifest.s_slots
          (Chunks.count ~size:new_size ~chunk_size:cs)
      in
      let st = { st with Staged_manifest.s_slots = slots; s_size = new_size } in
      let first = Chunks.index_of ~chunk_size:cs start in
      let last =
        if len = 0 then first
        else Chunks.index_of ~chunk_size:cs (start + len - 1)
      in
      (* Asked of every member of a group, not just the chunk being written, so
         overwriting a whole file costs no reads. *)
      let covers j =
        let chunk_start = Chunks.offset_of ~chunk_size:cs j in
        start <= chunk_start
        && start + len
           >= chunk_start + Chunks.length_of ~size:new_size ~chunk_size:cs j
      in
      let rec go i =
        if i > last then return_unit
        else (
          let chunk_off = if i = first then start mod cs else 0 in
          let take =
            min (cs - chunk_off)
              (len - (Chunks.offset_of ~chunk_size:cs i + chunk_off - start))
          in
          let* () = ensure_group_body ~base ~st ~covers i in
          let* () =
            match st.Staged_manifest.s_slots.(i) with
              | Staged_manifest.Staged { uuid; offset = body_off } ->
                  let src_off =
                    Chunks.offset_of ~chunk_size:cs i + chunk_off - start
                  in
                  let slice = Bigarray.Array1.sub buf src_off take in
                  let+ (_ : int) =
                    Sb.write ~uuid slice ~offset:(body_off + chunk_off)
                  in
                  ()
              | Staged_manifest.Inherit | Staged_manifest.Zero ->
                  (* [ensure_group_body] just made this a staged body. *)
                  Io.fail (Failure "data: slot not staged")
          in
          go (i + 1))
      in
      let* () = go first in
      let+ () = Mfs.write key (mutated st) in
      len

    (* A grow is pure metadata: new chunks are holes until written. *)
    let write key buf ~offset =
      with_key key (fun () -> write_locked key buf ~offset)

    let truncate_locked key size =
      let* st = staged_for key in
      let* base = Mf.published key in
      let cs = st.Staged_manifest.s_chunk_size in
      let n = Chunks.count ~size ~chunk_size:cs in
      let old = st.Staged_manifest.s_slots in
      let slots = grow_slots (Array.sub old 0 (min n (Array.length old))) n in
      (* By difference, not per dropped slot: the members of a group share one
         body, and one of them surviving keeps it. *)
      let* () =
        let kept = Staged_manifest.body_uuids slots in
        iter_s
          (fun uuid ->
            if List.mem uuid kept then return_unit else Sb.forget ~uuid)
          (Staged_manifest.body_uuids old)
      in
      let st = { st with Staged_manifest.s_slots = slots; s_size = size } in
      let* () =
        let i = n - 1 in
        if i < 0 then return_unit
        else (
          let len = Chunks.length_of ~size ~chunk_size:cs i in
          match slots.(i) with
            | Staged_manifest.Staged { uuid; offset } ->
                Sb.resize ~uuid ~len:(offset + len)
            | Staged_manifest.Zero -> return_unit
            | Staged_manifest.Inherit -> (
                let inherited_len =
                  match base with
                    | Some m ->
                        Chunks.length_of ~size:(Manifest.size m)
                          ~chunk_size:(Manifest.chunk_size m) i
                    | None -> 0
                in
                if inherited_len = len then return_unit
                else
                  let* () =
                    ensure_group_body ~base ~st ~covers:(fun _ -> false) i
                  in
                  match slots.(i) with
                    | Staged_manifest.Staged { uuid; offset } ->
                        Sb.resize ~uuid ~len:(offset + len)
                    | Staged_manifest.Inherit | Staged_manifest.Zero ->
                        return_unit))
      in
      Mfs.write key (mutated st)

    let discard_bodies (st : Staged_manifest.staged) =
      let* () =
        iter_s
          (fun uuid -> Sb.forget ~uuid)
          (Staged_manifest.body_uuids st.Staged_manifest.s_slots)
      in
      match st.Staged_manifest.s_whole with
        | Some uuid -> Sb.whole_forget ~uuid
        | None -> return_unit

    let truncate key size = with_key key (fun () -> truncate_locked key size)

    let discard_staged_locked key =
      let* st = Mfs.read_edits key in
      let* () =
        match st with Some st -> discard_bodies st | None -> return_unit
      in
      Mfs.delete key

    (* Staged bodies are named by uuid and referenced only from staged manifests,
       so a body no manifest names is unreachable by construction.

       Startup only: {!stage_slot} creates a body before the manifest records it,
       so mid-session an unreferenced body can be one a write is about to use. *)
    let reclaim_staged_orphans () =
      let* uuids = Mfs.uuids () in
      let live = Hashtbl.create (List.length uuids) in
      List.iter (fun uuid -> Hashtbl.replace live uuid ()) uuids;
      let sweep dir =
        let* exists = Fs.is_directory dir in
        if not exists then return_unit
        else
          let* names = Fs.readdir_list dir in
          iter_s
            (fun name ->
              if Hashtbl.mem live name then return_unit
              else (
                Log.info "reclaiming orphaned staged body %s" name;
                Fs.unlink_quiet (Filename.concat dir name)))
            names
      in
      let* () =
        sweep
          (Cache_layout.staged_chunks_dir ~cache_root:C.cache_root C.domain_name)
      in
      let* () =
        sweep
          (Cache_layout.staged_whole_dir ~cache_root:C.cache_root C.domain_name)
      in
      Mfs.prune_dirs ()

    let discard_staged key = with_key key (fun () -> discard_staged_locked key)

    let create_locked key =
      let* st = Mfs.read_edits key in
      let* () =
        match st with Some st -> discard_bodies st | None -> return_unit
      in
      let name = Logical_key.leaf key in
      let* chunk_size = R.chunk_size () in
      Mfs.write key
        {
          Staged_manifest.s_name = name;
          s_size = 0L;
          s_mtime = Unix.gettimeofday ();
          s_chunk_size = chunk_size;
          s_slots = [||];
          s_whole = None;
        }

    let create key = with_key key (fun () -> create_locked key)

    (* A staged body is whatever the writer left on disk and may fall short of its
       chunk length, grown by a truncate that never wrote or lost entirely.

       The manifest's length wins either way, so a short or missing body zeroes the
       tail rather than shrinking the chunk. *)
    let fill_from_staged ~uuid ~offset ~len buf =
      let* fd =
        Io.catch
          (fun () ->
            let+ fd = Retry.openfile (Sb.path uuid) [Unix.O_RDONLY] 0 in
            Some fd)
          (fun _ -> Io.return None)
      in
      match fd with
        | None ->
            Fs.zero buf ~pos:0 ~len;
            return_unit
        | Some fd ->
            Io.finalize
              (fun () ->
                let rec loop pos =
                  if pos >= len then return_unit
                  else
                    let* n =
                      Fs.pread fd buf ~file_offset:(offset + pos) pos (len - pos)
                    in
                    (* Short of [len]: the rest of the chunk is a hole. *)
                    if n = 0 then (
                      Fs.zero buf ~pos ~len:(len - pos);
                      return_unit)
                    else loop (pos + n)
                in
                loop 0)
              (fun () -> Retry.close fd)

    (* Deciding which source a chunk has must stay I/O-free: the reads happen
       inside the fillers, once {!Remote.upload_chunks} has a buffer to hand
       them. *)
    let staged_source ~(staged : Staged_manifest.staged) ~base i =
      let cs = staged.Staged_manifest.s_chunk_size in
      let len =
        Chunks.length_of ~size:staged.Staged_manifest.s_size ~chunk_size:cs i
      in
      (* A hole is still named and stored: it is bytes the file holds, and every
         chunk of a published file has a key. *)
      let zeroes =
        Chunk_source.Filled
          {
            len;
            fill =
              (fun buf ->
                Fs.zero buf ~pos:0 ~len;
                return_unit);
          }
      in
      let slots = staged.Staged_manifest.s_slots in
      if i >= Array.length slots then Io.return zeroes
      else (
        match slots.(i) with
          | Staged_manifest.Zero -> Io.return zeroes
          | Staged_manifest.Inherit -> (
              match base with
                | Some m when i < Manifest.count m ->
                    Io.return (Chunk_source.Stored (Manifest.key m i))
                | Some _ | None ->
                    Io.fail
                      (Backend.Backend_error
                         (Printf.sprintf "staged chunk %d inherits nothing" i)))
          | Staged_manifest.Staged { uuid; offset } ->
              Io.return
                (Chunk_source.Filled
                   { len; fill = fill_from_staged ~uuid ~offset ~len }))

    let rec upload_staged ~key ~(staged : Staged_manifest.staged) ?cancel () =
      match staged.Staged_manifest.s_whole with
        | Some uuid ->
            let* chunk_size = R.chunk_size () in
            let* state =
              R.upload ~key ~src_path:(Sb.whole_path uuid)
                ~mtime:staged.Staged_manifest.s_mtime ~chunk_size ?cancel ()
            in
            commit key staged state
        | None -> upload_chunked ~key ~staged ?cancel ()

    and upload_chunked ~key ~(staged : Staged_manifest.staged) ?cancel () =
      let* base = Mf.published key in
      let* state =
        R.upload_chunks ~key ~size:staged.Staged_manifest.s_size
          ~chunk_size:staged.Staged_manifest.s_chunk_size
          ~mtime:staged.Staged_manifest.s_mtime
          ~source:(staged_source ~staged ~base)
          ?cancel ()
      in
      commit key staged state

    and commit key (staged : Staged_manifest.staged) published =
      let+ () = Mfs.commit key staged published in
      published

    (* Every step is idempotent, so a crash anywhere replays.

       Bodies go last, after the published manifest and after the marker that
       chooses between the two: a reader resolving the key partway through has to
       find whichever representation it lands on still on disk. *)
    let rec promote key (staged : Staged_manifest.staged)
        (published : Manifest.t) =
      match staged.Staged_manifest.s_whole with
        | Some uuid ->
            (* The chunk store deliberately ends up with none of this file's
               chunks: the only caller handing over whole files is the FileProvider
               extension, which already keeps its own copy, and caching the bytes
               again would double the disk cost of every edit. *)
            let* () = Mf.write key published in
            let* () = Mfs.delete key in
            Sb.whole_forget ~uuid
        | None -> promote_chunked key staged published

    and promote_chunked key (staged : Staged_manifest.staged)
        (published : Manifest.t) =
      let slots = staged.Staged_manifest.s_slots in
      let slot_at i =
        if i < Array.length slots then slots.(i) else Staged_manifest.Zero
      in
      let touched group =
        List.exists
          (fun i ->
            match slot_at i with Staged_manifest.Staged _ -> true | _ -> false)
          (Manifest.Group.indices group)
      in
      (* [stage_group] stages a group whole, so a touched group has every member
         on disk; anything else would come from the old, invalidated group key. *)
      let local group =
        List.for_all
          (fun i ->
            match slot_at i with
              | Staged_manifest.Staged _ | Staged_manifest.Zero -> true
              | Staged_manifest.Inherit -> false)
          (Manifest.Group.indices group)
      in
      (* Anything else -- a body per chunk from an older sidecar, or a group the
         cache size no longer matches -- has to be written out. *)
      (* The staged record's own account of the group's length, which the link
         refuses unless it matches the published group's. *)
      let staged_len group =
        let indices = Manifest.Group.indices group in
        match indices with
          | [] -> 0
          | first :: _ ->
              let last = List.nth indices (List.length indices - 1) in
              snd (group_layout ~st:staged ~first ~last)
      in
      let single_body group =
        shared_body ~slot_at
          (List.map
             (fun i -> (i, Manifest.Group.offset group i))
             (Manifest.Group.indices group))
      in
      let write_group group =
        Cc.put_group ~group ~member:(fun i ->
            let* source = staged_source ~staged ~base:None i in
            match source with
              | Chunk_source.Stored _ | Chunk_source.Mapped _ ->
                  assert false (* [local] ruled these out *)
              | Chunk_source.Filled { len; fill } ->
                  (* Its own buffer rather than one of the upload path's slots:
                     this runs over a group's members, two at the defaults. *)
                  let buf = Bigstring.create len in
                  let+ () = fill buf in
                  buf)
      in
      (* An untouched group keeps its key, so whatever body we hold for it is
         still right. *)
      let* () =
        iter_s
          (fun group ->
            if not (touched group && local group) then return_unit
            else (
              match single_body group with
                | Some uuid ->
                    let* linked =
                      Sb.link_group ~uuid ~len:(staged_len group) ~group
                    in
                    if linked then return_unit else write_group group
                | None -> write_group group))
          (groups published)
      in
      let* () = Mf.write key published in
      let* () = Mfs.delete key in
      discard_bodies staged

    (* Read again under the lock rather than promoting the record the upload
       started from: a write since then has retired it, and what it describes is
       no longer what the file holds. The next close or the next start queues the
       upload that owes. *)
    let promote_pending key =
      with_key key (fun () ->
          let* state = Mfs.read key in
          match state with
            | Some (Staged_manifest.Committed (staged, published)) ->
                promote key staged published
            | _ ->
                Log.debug "sync %s: superseded before promotion"
                  (Logical_key.to_string key);
                return_unit)

    (* A staged manifest already carrying a published one was interrupted
       mid-promotion: finish it without re-uploading. *)
    let sync key ?cancel () =
      let* state = Mfs.read key in
      match state with
        | None -> return_unit
        | Some (Staged_manifest.Committed _) -> promote_pending key
        | Some (Staged_manifest.Owed staged) ->
            let* (_ : Manifest.t) = upload_staged ~key ~staged ?cancel () in
            promote_pending key

    (* Re-exported so a domain has exactly one {!Chunk_cache} instance: two would
       each keep their own in-flight table and stop deduplicating downloads. *)

    let enforce_chunk_cap = Cc.enforce_cap
    let chunk_stats = Cc.stats
    let downloads_in_flight = Cc.in_flight

    (* Adopts [src_path] by rename: no copy, no chunking pass; the upload reads it
       directly. *)
    let stage_whole_locked key ~src_path =
      let* st = Mfs.read_edits key in
      let* () =
        match st with Some st -> discard_bodies st | None -> return_unit
      in
      let* stat = Retry.LargeFile.stat src_path in
      let* chunk_size = R.chunk_size () in
      let uuid = Staged_manifest.new_uuid () in
      let* () = Sb.adopt_whole ~src:src_path ~uuid in
      Mfs.write key
        {
          Staged_manifest.s_name = Logical_key.leaf key;
          s_size = stat.Unix.LargeFile.st_size;
          s_mtime = stat.Unix.LargeFile.st_mtime;
          s_chunk_size = chunk_size;
          s_slots = [||];
          s_whole = Some uuid;
        }

    let stage_whole key ~src_path =
      with_key key (fun () -> stage_whole_locked key ~src_path)

    let staged_body_path key =
      let+ st = Mfs.read_edits key in
      match st with
        | Some { Staged_manifest.s_whole = Some uuid; _ } ->
            Some (Sb.whole_path uuid)
        | _ -> None

    (* Staged bodies count as present: they are the newest bytes there are. *)
    let chunk_residency key =
      let* resolved = Mf.current key in
      match resolved with
        | None -> Io.return (0, 0)
        | Some (`Published m) ->
            let total = Manifest.count m in
            let+ present =
              fold_left_s
                (fun acc group ->
                  let+ here = Cc.exists group in
                  if here then acc + Manifest.Group.member_count group else acc)
                0 (groups m)
            in
            (present, total)
        | Some (`Staged (({ Staged_manifest.s_whole = Some _; _ } as st), _)) ->
            let n =
              Chunks.count ~size:st.Staged_manifest.s_size
                ~chunk_size:st.Staged_manifest.s_chunk_size
            in
            Io.return (n, n)
        | Some (`Staged (st, base)) ->
            let slots = st.Staged_manifest.s_slots in
            let total = Array.length slots in
            let+ present =
              fold_left_s
                (fun acc i ->
                  match slots.(i) with
                    | Staged_manifest.Staged _ | Staged_manifest.Zero ->
                        Io.return (acc + 1)
                    | Staged_manifest.Inherit -> (
                        match group_at_opt base i with
                          | Some group ->
                              let+ here = Cc.exists group in
                              if here then acc + 1 else acc
                          | None -> Io.return acc))
                0 (List.init total Fun.id)
            in
            (present, total)

    (* [total] counts fetch *and* reassembly bytes: a bar that stops at the end of
       the fetch cannot be told from a hang.

       [holders] lets two materializations of one key share a row instead of the
       first to finish taking it away from the other. *)
    type span = { mutable fetched : int; total : int; mutable holders : int }

    let active : (string, span) Hashtbl.t = Hashtbl.create 8

    let download_progress key =
      Option.map
        (fun s -> (s.fetched, s.total))
        (Hashtbl.find_opt active (Logical_key.to_string key))

    (* Clamped: a group already on disk is credited in full, so a re-fetch would
       otherwise push the bar past its end. *)
    let credit key n =
      match Hashtbl.find_opt active key with
        | Some s -> s.fetched <- min s.total (s.fetched + n)
        | None -> ()

    let with_span key ~total f =
      let key = Logical_key.to_string key in
      (match Hashtbl.find_opt active key with
        | Some s -> s.holders <- s.holders + 1
        | None -> Hashtbl.replace active key { fetched = 0; total; holders = 1 });
      Io.finalize f (fun () ->
          (match Hashtbl.find_opt active key with
            | Some s when s.holders <= 1 -> Hashtbl.remove active key
            | Some s -> s.holders <- s.holders - 1
            | None -> ());
          return_unit)

    let groups_bytes groups =
      List.fold_left (fun acc g -> acc + Manifest.Group.bytes g) 0 groups

    (* Wide enough to keep {!Chunk_cache}'s own download bound saturated, and no
       wider: a whole-file materialization is one element per group, so a 250 GB
       archive is sixteen thousand of them and each does a stat and a table insert
       before it ever queues for a download slot. Its own pool, the one inside
       [ensure_fetched] being what the work then waits on. *)
    let group_slots = Bounded.create ~max:(4 * max 1 C.max_downloads) ()

    (* ponytail: credit is per group — 16 MB at the defaults, so a file smaller
       than one group only moves when it finishes; doing it per stored chunk needs
       a listener registry, since {!Chunk_cache.ensure} hands a second caller the
       in-flight promise without its callback. *)
    let fetch_groups key groups =
      let key = Logical_key.to_string key in
      (* What is owed the network, not the size of the file: a partly cached file
         finishes sooner, and an ETA is against what is left to come down. *)
      let owed = groups_bytes groups in
      Bounded.iter_with group_slots
        (fun group ->
          let+ fetched = Cc.ensure_fetched ~group () in
          let bytes = Manifest.Group.bytes group in
          (* The bar counts every group: one already on disk is progress toward a
             materialized file. The tray row counts only what crossed the wire, or
             a part-cached file credits its local groups at once and reads as a
             rate in the gigabytes. *)
          credit key bytes;
          if fetched then credit_pull key ~size:owed bytes)
        groups

    (* Counted here, not at the callers, so every route to a materialized file is
       included. *)
    let downloads_completed = ref 0
    let downloads_completed_count () = !downloads_completed

    (* Which groups [key] still owes the network, resolved up front so a caller
       can size a progress bar; [None] is "nothing to materialize", distinct from
       the empty list a chunkless file gives. *)
    let fetch_plan key =
      let* resolved = Mf.current key in
      match resolved with
        | Some (`Published m) -> return_some (groups m)
        | Some (`Staged (st, base)) -> (
            match base with
              | None -> Io.return None
              | Some m ->
                  let slots = st.Staged_manifest.s_slots in
                  let still_inherited i =
                    i < Array.length slots
                    && slots.(i) = Staged_manifest.Inherit
                  in
                  return_some
                    (List.filter
                       (fun g ->
                         List.exists still_inherited (Manifest.Group.indices g))
                       (groups m)))
        | None -> (
            let* state = R.fetch_manifest ~key () in
            match state with
              | Some m ->
                  let* () = Mf.write key m in
                  return_some (groups m)
              | None -> Io.return None)

    let content_size key =
      let+ resolved = Mf.current key in
      match resolved with
        | Some (`Published m) -> Int64.to_int (Manifest.size m)
        | Some (`Staged (st, _)) -> Int64.to_int st.Staged_manifest.s_size
        | None -> 0

    let ensure_local key =
      let* plan = fetch_plan key in
      match plan with
        | None -> return_unit
        | Some groups ->
            with_span key ~total:(groups_bytes groups) (fun () ->
                let+ () = fetch_groups key groups in
                incr downloads_completed)

    (* Goes through the ordinary read path, so staged edits, inherited chunks and
       holes all come out right and the chunk store is populated on the way. *)
    let assemble_to key ~dst_path =
      let* () = Fs.ensure_parent dst_path in
      let* plan = fetch_plan key in
      let* size = content_size key in
      let to_fetch = match plan with None -> 0 | Some gs -> groups_bytes gs in
      with_span key ~total:(to_fetch + size) @@ fun () ->
      let* () =
        match plan with
          | None -> return_unit
          | Some groups ->
              let+ () = fetch_groups key groups in
              incr downloads_completed
      in
      let buf =
        Bigarray.Array1.create Bigarray.char Bigarray.c_layout cache_chunk_size
      in
      let* fd =
        Retry.openfile dst_path
          [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
          0o644
      in
      let* () = Retry.close fd in
      let rec go offset =
        let* n = pread_key key buf ~offset in
        if n <= 0 then return_unit
        else
          let* (_ : int) =
            Fs.write dst_path (Bigarray.Array1.sub buf 0 n) ~offset
          in
          credit (Logical_key.to_string key) n;
          go (Int64.add offset (Int64.of_int n))
      in
      let* () = go 0L in
      (* An export or handoff copy should carry the source file's mtime. *)
      let* resolved = Mf.current key in
      match resolved with
        | Some (`Staged (st, _)) ->
            Retry.utimes dst_path st.Staged_manifest.s_mtime
              st.Staged_manifest.s_mtime
        | Some (`Published m) ->
            Retry.utimes dst_path (Manifest.mtime m) (Manifest.mtime m)
        | None -> return_unit

    (* ponytail: no progress span — a range is bounded by construction and its
       caller knows how many bytes it asked for. *)
    let fetch_range key ~dst_path ~offset ~length =
      let* () = Fs.ensure_parent dst_path in
      let* fd = Retry.openfile dst_path [Unix.O_WRONLY; Unix.O_CREAT] 0o644 in
      let* () = Retry.close fd in
      let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout length in
      let offset = Int64.of_int offset in
      let* n = pread_key key buf ~offset in
      let+ (_ : int) =
        Fs.write dst_path (Bigarray.Array1.sub buf 0 n) ~offset
      in
      n

    (* Unreference-blind: a chunk shared with another file goes too and is
       re-fetched on demand, which is what avoids refcounting. *)
    let forget_chunks key =
      let* published = Mf.published key in
      match published with
        | Some m -> iter_s (fun group -> Cc.forget ~group) (groups m)
        | None -> return_unit
  end
end
