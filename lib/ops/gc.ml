open Lwt.Syntax

type outcome = Completed | Suspended of { phase : string; cursor : string }

type stats = {
  outcome : outcome;
  roots_marked : int;
  chunks_promoted : int;
  chunks_reclaimed : int;
  bytes_reclaimed : int;
}

exception Unsupported of string
exception Busy of string

let () =
  Printexc.register_printer (function
    | Unsupported msg | Busy msg -> Some msg
    | _ -> None)

let empty =
  {
    outcome = Completed;
    roots_marked = 0;
    chunks_promoted = 0;
    chunks_reclaimed = 0;
    bytes_reclaimed = 0;
  }

module Make (C : Conf.S) = struct
  module Space = Chunk_space.Make (C)
  module B = (val C.store : Backend.S)

  (* Asked per item: a clock read against a rename is nothing, and every coarser
     unit here can take minutes. Returns whether it fired, so other once-a-second
     work can hang off the same clock. *)
  let report_interval = 1.
  let last_report = ref neg_infinity

  let throttled f =
    let now = Unix.gettimeofday () in
    if now -. !last_report >= report_interval then begin
      last_report := now;
      f ();
      true
    end
    else false

  (* Opening and closing a run are a rename and an [rm -rf] within the main's own
     directory, which is exactly what {!Backend.caps.gc} claims. *)
  let collector () =
    let main =
      List.find_opt
        (fun (m : Backend.member) -> m.Backend.role = "main")
        C.members
    in
    match main with
      | None ->
          Lwt.fail
            (Unsupported
               (Printf.sprintf "%s has no main store to collect." C.domain_name))
      | Some m -> (
          let (module M : Backend.S) = m.Backend.backend in
          let* caps = M.capabilities ~prefix:C.domain_prefix () in
          match (caps.Backend.gc, m.Backend.local_path) with
            | true, Some root -> Lwt.return ((module M : Backend.S), root)
            | _ ->
                Lwt.fail
                  (Unsupported
                     (Printf.sprintf
                        "Collecting chunks needs a local main store; %s is %s. \
                         Versions and the journal can still be trimmed with \
                         tsync expire."
                        m.Backend.name m.Backend.backend_type)))

  (* Trailing slashes off: these name directories to rename and remove, not keys,
     and [rename] rejects a path ending in one on some systems. *)
  let dir_of_prefix prefix =
    if String.ends_with ~suffix:"/" prefix then
      String.sub prefix 0 (String.length prefix - 1)
    else prefix

  let to_dir root = Filename.concat root (dir_of_prefix C.chunk_prefix)
  let from_dir root = Filename.concat root (dir_of_prefix Space.from_prefix)

  (* Keys per delete against a copy. 1000 is what s3 and gcs both cap a bulk
     delete at; an http-proxy posts the whole list and its ceiling is the peer's
     body limit, a local store unlinks in turn. A knob rather than a constant
     because the ceiling is the store's, not ours.

     A key count rather than a shard count: shards hold anything from nothing to
     thousands, so a fixed number of them is a round trip wasted on the empty
     ones and a batch over the limit on the full ones. *)
  let default_delete_batch = 1000

  let deferred_members () =
    List.filter
      (fun (m : Backend.member) ->
        m.Backend.role = "replica" || m.Backend.role = "backfill")
      C.members

  (* Two processes stepping one run lose chunks: both resume from the same
     cursor, so their root lists can partition, and whichever finishes its share
     first starts discarding the old space while the other still has roots
     nothing has promoted.

     A lock file rather than another key, because [lockf] is released by the
     kernel when the holder dies: a crashed collection must leave a resumable
     run, not a run nobody may touch.

     ponytail: the lock is on the main's own filesystem, so two hosts sharing a
     main over a network filesystem could still both step one run. *)
  let lock_path root = Filename.concat root (Space.marker_key ^ ".lock")

  let describe_open_run () =
    let+ run = Space.read_run () in
    match run with
      | None -> ""
      | Some r ->
          Printf.sprintf " (%s, started %.0fs ago)"
            (Chunk_space.string_of_phase r.Chunk_space.phase)
            (Unix.gettimeofday () -. r.Chunk_space.started)

  (* A record lock merges with one the same process already holds rather than
     reporting contention, so this process needs its own answer: two sessions
     here would otherwise interleave the way two processes must not. *)
  let held = ref false

  let busy () =
    let+ detail = describe_open_run () in
    Busy
      (Printf.sprintf
         "A collection of %s is already running%s. Wait for it, or stop it and \
          use tsync gc --abort."
         C.domain_name detail)

  let take_lock root =
    if !held then
      let* exn = busy () in
      Lwt.fail exn
    else (
      let path = lock_path root in
      let* () = Fs_util.ensure_parent path in
      let* fd = Lwt_unix.openfile path [Unix.O_RDWR; Unix.O_CREAT] 0o644 in
      Lwt.catch
        (fun () ->
          let+ () = Lwt_unix.lockf fd Unix.F_TLOCK 0 in
          held := true;
          fd)
        (function
          | Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES | Unix.EDEADLK), _, _)
            ->
              let* () = Lwt_unix.close fd in
              let* exn = busy () in
              Lwt.fail exn
          | exn ->
              let* () = Lwt_unix.close fd in
              Lwt.fail exn))

  (* Closing the descriptor drops the lock; worth doing even though exiting
     would, since a process that collects twice must not go on holding it. *)
  let drop_lock fd =
    held := false;
    Lwt.catch
      (fun () -> Lwt_unix.close fd)
      (function Unix.Unix_error _ -> Lwt.return_unit | exn -> Lwt.fail exn)

  (* A plain rename into a fresh name in the same parent, so it is atomic and
     needs no [RENAME_EXCHANGE] stunt.

     [chunks/] is not recreated: every writer runs [ensure_parent] first, so the
     surviving space appears when something lands in it. *)
  let open_space root =
    let src = to_dir root and dst = from_dir root in
    let* exists = Lwt_unix_retry.file_exists dst in
    if exists then Lwt.return_unit (* a previous attempt got this far *)
    else
      Lwt.catch
        (fun () -> Lwt_unix_retry.rename src dst)
        (function
          | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
          | exn -> Lwt.fail exn)

  (* A namespace is a name in one of the two directories that can hold something
     referencing a chunk: [manifests/<folder-id>/...] and
     [versions/<folder-id>/...]. Tagged so the two cannot collide in a cursor,
     and so that manifests sort first. *)
  let encode which id =
    (match which with `Manifests -> "m" | `Versions -> "v") ^ "/" ^ id

  let decode ns =
    let id = String.sub ns 2 (String.length ns - 2) in
    ((if ns.[0] = 'v' then `Versions else `Manifests), id)

  (* Enumerated a namespace at a time rather than by listing both prefixes whole:
     a whole listing walks every object in the store before the first chunk is
     marked, and is paid again on every resume.

     Sorted, so a resume can skip what is done; a namespace created after this
     read is missed and needs no catching, whatever writes it promoting its own
     chunks when it publishes. *)
  let namespaces root =
    let read dir = Fs_util.readdir_list_quiet (Filename.concat root dir) in
    let* manifests = read (dir_of_prefix C.domain_prefix) in
    let+ versions = read (dir_of_prefix C.versions_prefix) in
    List.map (encode `Manifests) manifests
    @ List.map (encode `Versions) versions
    |> List.sort String.compare

  (* The trailing slash is not decoration: a backend builds the keys it lists by
     concatenating this onto each entry it finds, so leaving it off yields
     [manifests/<id><hash>] — every lookup comes back empty, nothing is promoted,
     and the collection then discards every chunk in the store.

     Hence the [`Dir] / [`File] distinction: a namespace that is really a single
     object must not have one. *)
  let prefix_of_namespace root ns =
    let base =
      let which, id = decode ns in
      (match which with
        | `Versions -> C.versions_prefix
        | `Manifests -> C.domain_prefix)
      ^ id
    in
    let+ kind = Fs_util.lstat_kind (Filename.concat root base) in
    match kind with `Dir -> base ^ "/" | _ -> base

  (* Directory and folder markers reference nothing. An unexpected parse failure
     raises rather than reporting "references nothing", which would let the run
     discard the file's chunks. *)
  let referenced_chunks key =
    if Key.is_dir key then Lwt.return []
    else
      let+ data = B.get ~key () in
      match Folder.marker_of_string data with
        | Some _ -> []
        | None -> (
            match Manifest.of_string data with
              | m ->
                  let t = m.Manifest.chunks in
                  List.init (Chunk_table.count t) (Chunk_table.key t)
              | exception e ->
                  failwith
                    (Printf.sprintf
                       "cannot read manifest %s (%s); aborting the collection \
                        with nothing discarded"
                       key (Printexc.to_string e)))

  (* Read from the directories rather than assumed to be all
     {!Chunk_layout.shards} of them: a store holding a handful of chunks occupies
     a handful of shards, and walking 4096 of anything to find them is work in
     proportion to the layout instead of to the data.

     The main's own spaces are the only ones walked at all. A copy is told which
     keys to delete rather than asked what it holds, which is what keeps that
     true of the whole collection and not just of this. *)
  let shards_in dir =
    let+ names = Fs_util.readdir_list_quiet dir in
    List.filter Chunk_layout.is_shard_name names

  (* Abandoning visits the space on its way out; closing visits both, since a shard
     may exist in either. *)
  let from_shards root =
    let+ going = shards_in (from_dir root) in
    List.sort String.compare going

  let live_shards root =
    let* surviving = shards_in (to_dir root) in
    let+ going = shards_in (from_dir root) in
    List.sort_uniq String.compare (surviving @ going)

  (* What is left in one shard of the space on its way out, which after a
     completed mark is the garbage itself: marking moves each live chunk across
     rather than linking it, so nothing has to be worked out here twice.

     The surviving space is still listed, for a case moving does not cover: a
     chunk can be orphaned and, during the run, uploaded again by a writer that
     never saw the outgoing copy. On the main that is harmless — the new name
     survives the discard — but deleting the key off a replica would take out a
     live chunk. Listed second so a {!Chunk_space.promote_all} landing between
     the two is seen rather than missed.

     Keys come back spelled as a target holds them, a target having no
     from-space. Nothing here holds more than a shard's worth of them, whatever
     the store's size. *)
  let orphans_in_shard ~main:(module M : Backend.S) shard =
    let prefix = C.chunk_prefix ^ shard ^ "/" in
    let* going = M.list_prefix ~prefix:(Space.from_prefix ^ shard ^ "/") () in
    let* surviving = M.list_prefix ~prefix () in
    let kept = Hashtbl.create 256 in
    List.iter
      (fun (e : Backend.file_entry) ->
        Hashtbl.replace kept (Filename.basename e.Backend.key) ())
      surviving;
    (* Only chunks: a write left in flight is discarded with the old space, but
       it was never a chunk — counting it would overstate what the collection
       recovered, and naming it in a delete would take out another client's
       upload. *)
    Lwt.return
      (List.fold_left
         (fun (keys, bytes) (e : Backend.file_entry) ->
           let name = Filename.basename e.Backend.key in
           if Hashtbl.mem kept name || not (Chunk_layout.is_chunk_key name) then
             (keys, bytes)
           else ((prefix ^ name) :: keys, bytes + e.Backend.size))
         ([], 0) going)

  type work =
    | Mark of string list
    | Keep of string list
    | Close of string list

  type session = {
    main : (module Backend.S);
    root : string;
    started : float;
    targets : Backend.member list;
    lock : Lwt_unix.file_descr;
    (* Which pool to use is decided by nesting depth, not by what is being
       iterated: whatever runs several at once takes from [unit_slots], the
       per-object work inside one of those from [item_slots].

       One shared pool deadlocks the moment every slot is held by an outer unit
       waiting for an inner one — the trap [Local_backend.list_prefix] documents,
       and one this has fallen into more than once by naming pools after the
       phase that happened to use them. *)
    unit_slots : Lwt_bounded.t;
    item_slots : Lwt_bounded.t;
    delete_batch : int;
    (* Consulted between units so a long batch cannot overshoot a caller's time
       limit. Always false unless someone set one. *)
    mutable out_of_time : unit -> bool;
    mutable finished : bool;
    mutable work : work;
    mutable total : int;
    mutable done_ : int;
    mutable roots_marked : int;
    mutable chunks_promoted : int;
    mutable chunks_reclaimed : int;
    mutable bytes_reclaimed : int;
    mutable on_mark :
      namespaces:int -> total:int -> roots:int -> promoted:int -> unit;
    mutable on_close : shards:int -> reclaimed:int -> unit;
  }

  let phase s =
    match s.work with
      | Mark _ -> "marking"
      | Keep _ -> "abandoning"
      | Close _ -> "closing"

  let done_ s = s.done_
  let total s = s.total
  let release s = drop_lock s.lock

  let cursor s =
    match s.work with
      | Mark (k :: _) | Keep (k :: _) | Close (k :: _) -> k
      | Mark [] | Keep [] | Close [] -> ""

  let stats s =
    {
      outcome =
        (if s.finished then Completed
         else Suspended { phase = phase s; cursor = cursor s });
      roots_marked = s.roots_marked;
      chunks_promoted = s.chunks_promoted;
      chunks_reclaimed = s.chunks_reclaimed;
      bytes_reclaimed = s.bytes_reclaimed;
    }

  let status () = Space.read_run ()

  let save s phase cursor =
    Space.write_run { Chunk_space.phase; started = s.started; cursor }

  let start ?concurrency ?delete_batch ?(keep = false) () =
    let* main, root = collector () in
    (* Under the lock before the marker is read, so the decision to open or resume
       is made by one process. *)
    let* lock = take_lock root in
    let* existing = Space.read_run () in
    let started, phase, cursor =
      match existing with
        | None -> (Unix.gettimeofday (), Chunk_space.Opening, "")
        | Some r -> (r.Chunk_space.started, r.phase, r.cursor)
    in
    (* I/O bound, so a batch wants concurrent syscalls rather than cores: the
       device's own answer by default, and 1 makes a run as unobtrusive as it
       can be. *)
    let (module M : Backend.S) = main in
    let* max_slots =
      match concurrency with
        | Some n -> Lwt.return (max 1 n)
        | None ->
            let+ caps = M.capabilities ~prefix:C.domain_prefix () in
            (* Clamped, not trusted: a bounded pool of zero admits nothing and the
               first step would wait forever. *)
            max 1 (Option.value caps.Backend.max_concurrency ~default:8)
    in
    let fresh work total =
      {
        main;
        root;
        started;
        targets = deferred_members ();
        lock;
        unit_slots = Lwt_bounded.create ~max:max_slots ();
        item_slots = Lwt_bounded.create ~max:max_slots ();
        (* Clamped, not trusted: a batch of zero never flushes on count and the
           phase would hold every doomed key until the last shard. *)
        delete_batch =
          max 1 (Option.value delete_batch ~default:default_delete_batch);
        out_of_time = (fun () -> false);
        finished = false;
        work;
        total;
        done_ = 0;
        roots_marked = 0;
        chunks_promoted = 0;
        chunks_reclaimed = 0;
        bytes_reclaimed = 0;
        on_mark = (fun ~namespaces:_ ~total:_ ~roots:_ ~promoted:_ -> ());
        on_close = (fun ~shards:_ ~reclaimed:_ -> ());
      }
    in
    (* Each phase is recorded before the step it names, so whatever state the
       store is in continues from there: an interrupted rename is redone, an
       interrupted mark resumes at its cursor, an interrupted close at its
       shard. *)
      match phase with
      (* Abandoning first, and its override before any phase it overrides: a
         guard placed after the constructors it is meant to take precedence over
         never fires for them. *)
      | Chunk_space.Abandoning ->
          let* shards = from_shards root in
          let pending =
            List.filter (fun s -> String.compare s cursor > 0) shards
          in
          Log.info "gc: resuming abandonment, %d shard(s) left to keep"
            (List.length pending);
          Lwt.return (fresh (Keep pending) (List.length pending))
      (* Takes no cursor from the phase it overrides: a cursor means something
         different in each phase, and one left by marking or closing says nothing
         about which shards still need keeping.

         Shards already discarded cannot be brought back, so this keeps what is
         still there, which is all it can promise. *)
      | _ when keep ->
          let* shards = from_shards root in
          Log.info
            "gc: abandoning the collection of %s, keeping everything left in \
             %d shard(s)"
            C.domain_name (List.length shards);
          let s = fresh (Keep shards) (List.length shards) in
          let+ () = save s Chunk_space.Abandoning "" in
          s
      | Chunk_space.Closing ->
          let* shards = live_shards root in
          let pending =
            List.filter (fun s -> String.compare s cursor > 0) shards
          in
          Log.info "gc: resuming, %d shard(s) to close" (List.length pending);
          Lwt.return (fresh (Close pending) (List.length pending))
      (* Once a collection has been called off it stays called off: coming back
         to an [Abandoning] run continues abandoning rather than quietly resuming
         a collection whoever stopped it did not want. *)
      | Chunk_space.Opening | Chunk_space.Marking ->
          if existing = None then
            Log.info "gc: opening a collection of %s" C.domain_name;
          let s = fresh (Mark []) 0 in
          let* () = save s Chunk_space.Opening "" in
          let* () = open_space root in
          (* Enumerated before the phase is recorded as [Marking], so a
               [--status] during it does not claim to be marking while it is still
               working out what to mark. *)
          let* found = namespaces root in
          let pending =
            List.filter (fun n -> String.compare n cursor > 0) found
          in
          let* () = save s Chunk_space.Marking cursor in
          Log.info "gc: %d namespace(s) to mark" (List.length pending);
          s.work <- Mark pending;
          s.total <- List.length pending;
          Lwt.return s

  (* Moves go out concurrently within the root: a big file naming thousands of
     chunks is otherwise thousands of serial [rename] calls. *)
  (* Per chunk, not per root: one video's manifest names a hundred thousand of
     them, and reporting after the root left the line reading "1 file, 0 chunks"
     for minutes, which reads as wedged. *)
  let report_mark s =
    ignore
      (throttled (fun () ->
           Log.debug
             "gc: marked %d/%d namespace(s), %d root(s), %d chunk(s) kept"
             s.done_ s.total s.roots_marked s.chunks_promoted;
           s.on_mark ~namespaces:s.done_ ~total:s.total ~roots:s.roots_marked
             ~promoted:s.chunks_promoted))

  let mark_root s key =
    let* chunks = referenced_chunks key in
    (* Before the work, so [-v] names the file while it is on it. *)
    Log.debug "gc: marking %s (%d chunk(s))" key (List.length chunks);
    let* () =
      Lwt_list.iter_p
        (fun ck ->
          Lwt_bounded.use s.item_slots (fun () ->
              let+ () = Space.promote ck in
              s.chunks_promoted <- s.chunks_promoted + 1;
              report_mark s))
        chunks
    in
    s.roots_marked <- s.roots_marked + 1;
    report_mark s;
    Lwt.return_unit

  (* Roots go out on [unit_slots] and the chunks within a root on [item_slots]:
     the caller must not also hold a [unit_slots] slot for the whole namespace,
     or every slot parks on a root waiting for a chunk. *)
  let mark_one s ns =
    let* prefix = prefix_of_namespace s.root ns in
    let* entries = B.list_prefix ~prefix () in
    (* Only what is positively a write in flight is skipped, not everything
       unrecognised: skipping is the dangerous direction here — a root not marked
       is a file's chunks reclaimed — whereas in a chunk shard it is the safe
       one, and the same rule in both places is how a first attempt at this
       discarded an entire store.

       Everything else is read and parsed, and something that will not parse
       stops the collection loudly with nothing discarded. *)
    let keys =
      List.filter_map
        (fun (e : Backend.file_entry) ->
          let k = e.Backend.key in
          if Key.is_dir k || Fs_util.is_temp_name (Filename.basename k) then
            None
          else Some k)
        entries
    in
    let* () =
      Lwt_list.iter_p
        (fun k -> Lwt_bounded.use s.unit_slots (fun () -> mark_root s k))
        keys
    in
    s.done_ <- s.done_ + 1;
    Log.debug "gc: marked namespace %s (%d root(s))" ns (List.length keys);
    Lwt.return_unit

  (* The cursor advances to the largest name done, and only once everything
     before it is done too. *)
  let last_of batch =
    List.fold_left (fun acc k -> if k > acc then k else acc) "" batch

  (* Not {!Fs_util.rm_rf}, which lstats every name before unlinking it and walks
     strictly one at a time: for a shard of six hundred chunks that is twelve
     hundred sequential syscalls to learn nothing, the entries of a shard being
     files.

     Missing or already empty is the ordinary case rather than an error: closing
     reaches shards marking emptied, and abandoning reaches shards it carried
     across whole. *)
  let discard_shard s shard =
    let dir = Filename.concat (from_dir s.root) shard in
    let* names = Fs_util.readdir_list_quiet dir in
    let* () =
      Lwt_list.iter_p
        (fun n ->
          Lwt_bounded.use s.item_slots (fun () ->
              Fs_util.unlink_quiet (Filename.concat dir n)))
        names
    in
    Lwt.catch
      (fun () -> Lwt_unix_retry.rmdir dir)
      (function Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)

  (* Deleted off the copies before the main discards them. Crashing in between
     leaves keys on a copy that the resumed run lists and deletes again, a repeat
     of something idempotent; the other way round leaks them for good, nothing
     walking a copy's own shards any more.

     Shards are discarded in one go with the delete rather than one at a time, so
     the cursor is only moved once everything before it is gone from every
     store. *)
  let flush_close s ~shards ~doomed ~reclaimed ~bytes =
    let* () =
      if doomed = [] then Lwt.return_unit
      else
        Lwt_list.iter_s
          (fun (m : Backend.member) ->
            let (module T : Backend.S) = m.Backend.backend in
            let+ () = T.delete_multi doomed in
            Log.debug "gc: %s: deleted %d chunk(s)" m.Backend.name reclaimed)
          s.targets
    in
    let* () = Lwt_list.iter_s (discard_shard s) shards in
    s.chunks_reclaimed <- s.chunks_reclaimed + reclaimed;
    s.bytes_reclaimed <- s.bytes_reclaimed + bytes;
    s.done_ <- s.done_ + List.length shards;
    let* () = save s Chunk_space.Closing (last_of shards) in
    ignore
      (throttled (fun () ->
           Log.debug "gc: %d/%d shard(s) closed, %d chunk(s) reclaimed" s.done_
             s.total s.chunks_reclaimed;
           s.on_close ~shards:s.done_ ~reclaimed:s.chunks_reclaimed));
    Lwt.return_unit

  (* Shards are scanned in order and their doomed keys pooled, so a store holding
     a handful of chunks in each pays one delete per copy for hundreds of shards
     rather than one per shard. Scanning is two local listings; the delete is a
     round trip, and it is the round trips this exists to spend fewer of.

     Hands back the shards it did not reach, so a caller's time limit stops this
     at a shard boundary with everything before it flushed. *)
  let close_batch s shards =
    let pending = ref [] and doomed = ref [] and count = ref 0 and bytes = ref 0 in
    let flush () =
      if !pending = [] then Lwt.return_unit
      else begin
        let shards = !pending and keys = !doomed in
        let reclaimed = !count and size = !bytes in
        pending := [];
        doomed := [];
        count := 0;
        bytes := 0;
        flush_close s ~shards ~doomed:keys ~reclaimed ~bytes:size
      end
    in
    let rec go = function
      | shard :: more when not (s.out_of_time ()) ->
          let* keys, size = orphans_in_shard ~main:s.main shard in
          pending := shard :: !pending;
          doomed := List.rev_append keys !doomed;
          count := !count + List.length keys;
          bytes := !bytes + size;
          (* Per shard, not per flush: a flush is a thousand keys away, which on
             a store with little garbage is the whole phase. Counts include what
             is pooled and not yet deleted. *)
          ignore
            (throttled (fun () ->
                 let scanned = s.done_ + List.length !pending in
                 Log.debug
                   "gc: %d/%d shard(s) scanned, %d chunk(s) to delete" scanned
                   s.total (s.chunks_reclaimed + !count);
                 s.on_close ~shards:scanned
                   ~reclaimed:(s.chunks_reclaimed + !count)));
          let* () =
            if !count >= s.delete_batch then flush () else Lwt.return_unit
          in
          go more
      | remaining ->
          let+ () = flush () in
          remaining
    in
    go shards

  (* A shard the surviving space has nothing of yet is carried over whole: one
     rename in place of a rename per chunk, which is most of a collection called
     off early, marking having reached almost none of the shards.

     [rename] onto a directory that exists and holds anything fails, so the
     shards marking did reach fall through to going chunk by chunk — which also
     settles the race: a writer landing a chunk between the attempt and now
     merely makes the rename fail. *)
  let carry_over s shard =
    let src = Filename.concat (from_dir s.root) shard
    and dst = Filename.concat (to_dir s.root) shard in
    Lwt.catch
      (fun () ->
        (* Counted before it moves: a carried shard keeps everything in it and
           would otherwise contribute nothing to the total. *)
        let* names = Fs_util.readdir_list src in
        let* () = Fs_util.ensure_parent dst in
        let+ () = Lwt_unix_retry.rename src dst in
        (* Counted, not filtered: the rename takes the whole directory and
           picking anything else out would cost the per-file work this exists to
           avoid, but what is not a chunk must not be reported as one. *)
        Some (List.length (List.filter Chunk_layout.is_chunk_key names)))
      (function
        (* The surviving space already has this shard: move the chunks instead. *)
        | Unix.Unix_error
            ((Unix.ENOTEMPTY | Unix.EEXIST | Unix.ENOTDIR | Unix.EISDIR), _, _)
          ->
            Lwt.return_none
        (* Nothing there to carry: already done, or never existed. *)
        | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return (Some 0)
        | exn -> Lwt.fail exn)

  let shard_dirs s shard =
    ( Filename.concat (from_dir s.root) shard,
      Filename.concat (to_dir s.root) shard )

  let read_dir dir =
    let+ names = Fs_util.readdir_list_quiet dir in
    List.filter Chunk_layout.is_chunk_key names

  let move_into ~src_dir ~dst_dir names =
    Lwt_list.iter_s
      (fun n ->
        Lwt.catch
          (fun () ->
            Lwt_unix_retry.rename
              (Filename.concat src_dir n)
              (Filename.concat dst_dir n))
          (function
            | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
            | exn -> Lwt.fail exn))
      names

  (* Emptying the surviving shard so the whole directory can be renamed into its
     place: ahead of an abandonment's cursor it holds one to six chunks against
     some six hundred in the space going away, and those few are the only thing
     making the directory rename fail.

     Nothing needs undoing if this stops half way: a shard left with an emptied
     surviving directory and everything in the old one is the state a fresh
     attempt handles best. *)
  let push_down s shard =
    let src_dir, dst_dir = shard_dirs s shard in
    let* here = read_dir dst_dir in
    let* theirs = read_dir src_dir in
    let below = Hashtbl.create (List.length theirs) in
    List.iter (fun n -> Hashtbl.replace below n ()) theirs;
    (* Unlinked, not moved, for the names the old space already has. Marking moves
       a chunk rather than copying it, so a name in both spaces means the old copy
       was never taken across and a writer put a second one here since — same
       name, same content, the name being the content's digest. Either will do and
       dropping this one is a syscall instead of two.

       A name the old space does not have is moved down instead, so either way
       the surviving directory ends up empty. *)
    let+ () =
      Lwt_list.iter_s
        (fun n ->
          if Hashtbl.mem below n then
            Fs_util.unlink_quiet (Filename.concat dst_dir n)
          else move_into ~src_dir:dst_dir ~dst_dir:src_dir [n])
        here
    in
    List.length here

  (* Chunk by chunk, for the shards where that is genuinely the cheaper way round:
     the surviving space holds most of one already, so moving the few that are
     missing beats pushing the many back down to rename the directory. *)
  let move_across s shard =
    let src_dir, dst_dir = shard_dirs s shard in
    let* names = read_dir src_dir in
    let* here = read_dir dst_dir in
    let present = Hashtbl.create (List.length here) in
    List.iter (fun n -> Hashtbl.replace present n ()) here;
    let missing = List.filter (fun n -> not (Hashtbl.mem present n)) names in
    let+ () =
      if missing = [] then Lwt.return_unit
      else
        let* () = Fs_util.mkdir_p dst_dir in
        Lwt_list.iter_p
          (fun n ->
            Lwt_bounded.use s.item_slots (fun () ->
                move_into ~src_dir ~dst_dir [n]))
          missing
    in
    List.length names

  (* Whichever way round is fewer operations, decided from the two counts:
     pushing [k] chunks down and renaming the directory costs [k + 1], moving the
     missing ones across costs [m - k], so the directory rename wins while the
     surviving space holds less than about half the shard. *)
  let keep_one s shard =
    let src_dir, dst_dir = shard_dirs s shard in
    let* kept =
      let* carried = carry_over s shard in
      match carried with
        | Some n -> Lwt.return n
        | None ->
            let* here = read_dir dst_dir in
            let* theirs = read_dir src_dir in
            let k = List.length here and m = List.length theirs in
            if k + 1 < m - k then
              let* _ = push_down s shard in
              let* carried = carry_over s shard in
              match carried with
                | Some n -> Lwt.return n
                (* Something landed in the shard while it was being emptied. Moving
                   what is missing is always correct, only dearer. *)
                | None -> move_across s shard
            else move_across s shard
    in
    s.chunks_promoted <- s.chunks_promoted + kept;
    (* Removed inside the loop that has a cursor, a budget and something to
       report: left to the end it was hundreds of thousands of sequential unlinks
       after the last shard, which reads exactly like a hang. *)
    let* () = discard_shard s shard in
    s.done_ <- s.done_ + 1;
    let* () = save s Chunk_space.Abandoning shard in
    (* [roots:0]: there are no files here, only shards. What the caller prints for
       a collection would read as a second, wrong count of them. *)
    ignore
      (throttled (fun () ->
           Log.debug "gc: kept %d/%d shard(s), %d chunk(s)" s.done_ s.total
             s.chunks_promoted;
           s.on_mark ~namespaces:s.done_ ~total:s.total ~roots:0
             ~promoted:s.chunks_promoted));
    Lwt.return_unit

  (* What is left in the old space is now garbage; the phase is recorded before
     the first shard is touched. *)
  let begin_closing s =
    let* shards = live_shards s.root in
    let* () = save s Chunk_space.Closing "" in
    (* The copies are named here rather than counted per flush: every one of them
       is sent the same list, so a per-copy total would be the same number said
       several times. *)
    Log.info "gc: marked %d root(s), %d chunk(s) kept; closing %d shard(s)%s"
      s.roots_marked s.chunks_promoted (List.length shards)
      (match s.targets with
        | [] -> ""
        | ms ->
            ", deleting on "
            ^ String.concat ", "
                (List.map (fun (m : Backend.member) -> m.Backend.name) ms));
    s.work <- Close shards;
    s.total <- List.length shards;
    s.done_ <- 0;
    Lwt.return_unit

  let finish s =
    let+ () = Space.clear_run () in
    s.finished <- true;
    Log.info "gc: done, %d chunk(s) reclaimed (%d byte(s))" s.chunks_reclaimed
      s.bytes_reclaimed

  (* Everything left of the old root is empty shards and the root itself. *)
  let discard_from_space s = Fs_util.rm_rf (from_dir s.root)

  (* Stops at a unit boundary when the caller's time is up and hands back what
     was not reached; each unit saves its own cursor. *)
  let each s f batch =
    let rec go = function
      | x :: more when not (s.out_of_time ()) ->
          let* () = f s x in
          go more
      | remaining -> Lwt.return remaining
    in
    go batch

  let take n l =
    let rec go acc n = function
      | rest when n <= 0 -> (List.rev acc, rest)
      | [] -> (List.rev acc, [])
      | x :: rest -> go (x :: acc) (n - 1) rest
    in
    go [] n l

  (* Switching phases is a step of its own rather than something folded into the
     first shard, so a caller driving this can stop between marking and
     discarding and the boundary is observable. *)
  let step ?(units = 1) s =
    match s.work with
      | Mark [] ->
          let+ () = begin_closing s in
          `More
      (* Abandoning ends here rather than going on through the phases a
         collection does: everything the discarded space held now has a name in
         the surviving one, so closing would count a reclaim defined to be zero
         and reconciling would ask every target about all 4096 shards to find
         orphans that cannot exist.

         Any shard still holding an old directory goes round again, in the loop
         with a cursor rather than in a sweep at the end; each pass removes
         directories, so this converges. *)
      | Keep [] ->
          let* leftover = from_shards s.root in
          if leftover <> [] then begin
            Log.info "gc: %d shard(s) of the old space still to remove"
              (List.length leftover);
            s.work <- Keep leftover;
            s.total <- List.length leftover;
            s.done_ <- 0;
            let+ () = save s Chunk_space.Abandoning "" in
            `More
          end
          else
            let* () = discard_from_space s in
            let+ () = finish s in
            `Done
      | Close [] ->
          let* () = discard_from_space s in
          let+ () = finish s in
          `Done
      (* [out_of_time] is consulted between units rather than only between whole
         steps: a namespace is a listing plus every manifest in it, so a batch of
         them can run for minutes and overshoot a budget by that much. *)
      | Keep shards ->
          let batch, rest = take (max 1 units) shards in
          let* remaining = each s keep_one batch in
          s.work <- Keep (remaining @ rest);
          Lwt.return `More
      | Mark namespaces ->
          let batch, rest = take (max 1 units) namespaces in
          (* The cursor advances per namespace, not per batch: a namespace can be
             a folder's worth of manifests, so saving at the end of a batch means
             an interruption throws away hours of promoting.

             Sound because namespaces here go one at a time; were they
             overlapped, "the last one finished" would not be the furthest one
             and saving it would strand the rest. *)
          let rec go = function
            | ns :: more when not (s.out_of_time ()) ->
                let* () = mark_one s ns in
                let* () = save s Chunk_space.Marking ns in
                go more
            | remaining -> Lwt.return remaining
          in
          let* remaining = go batch in
          s.work <- Mark (remaining @ rest);
          Lwt.return `More
      (* Shards are scanned one after another rather than concurrently: the scan
         is two local listings, and the round trip they feed is shared by however
         many shards the batch pools, so overlapping them buys little and makes
         the cursor mean less. *)
      | Close shards ->
          let batch, rest = take (max 1 units) shards in
          let* remaining = close_batch s batch in
          s.work <- Close (remaining @ rest);
          Lwt.return `More

  let run ?budget ?(units = 256) ?pause ?concurrency ?delete_batch
      ?(keep = false) ?(on_open = fun () -> ())
      ?(on_mark = fun ~namespaces:_ ~total:_ ~roots:_ ~promoted:_ -> ())
      ?(on_close = fun ~shards:_ ~reclaimed:_ -> ()) () =
    let began = Unix.gettimeofday () in
    let deadline =
      match budget with
        | None -> fun () -> false
        | Some seconds -> fun () -> Unix.gettimeofday () -. began >= seconds
    in
    on_open ();
    let* s = start ?concurrency ?delete_batch ~keep () in
    s.out_of_time <- deadline;
    s.on_mark <- on_mark;
    s.on_close <- on_close;
    let rec loop () =
      let* outcome = step ~units s in
      match outcome with
        | `Done -> Lwt.return (stats s)
        | `More ->
            if deadline () then begin
              (* The budget and what it actually took, because "out of budget"
                 alone cannot be checked against anything: a limit honoured to
                 the second and one overshot twentyfold read identically. *)
              Log.info "gc: %.0fs budget spent in %.0fs while %s; run left open"
                (Option.value budget ~default:0.)
                (Unix.gettimeofday () -. began)
                (phase s);
              Lwt.return (stats s)
            end
            else
              let* () =
                match pause with
                  | None -> Lwt.return_unit
                  | Some seconds -> Lwt_unix.sleep seconds
              in
              loop ()
    in
    (* Released whichever way this ends, including on the exception a failed
       manifest raises: a run left open is resumable, a lock held for the life of
       the process is not. *)
    Lwt.finalize loop (fun () -> release s)

  (* Abandoning is a collection in which every chunk turns out to be live, so it
     is {!run} with the marking phase pointed at the space on its way out: the
     shard cursor, the budget, the pause, the bounded concurrency and the
     progress all come along, and so does the lock. *)
  let abort ?budget ?units ?pause ?concurrency ?on_open ?on_mark ?on_close () =
    let* open_ = Space.read_run () in
    match open_ with
      | None -> Lwt.return empty
      | Some _ ->
          run ~keep:true ?budget ?units ?pause ?concurrency ?on_open ?on_mark
            ?on_close ()
end
