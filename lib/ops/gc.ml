open Lwt.Syntax

type outcome = Completed | Suspended of { phase : string; cursor : string }

type member_stats = { name : string; deleted : int; uploaded : int }

type stats = {
  outcome : outcome;
  roots_marked : int;
  chunks_promoted : int;
  chunks_reclaimed : int;
  bytes_reclaimed : int;
  members : member_stats list;
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
    members = [];
  }

module Make (C : Conf.S) = struct
  module Space = Chunk_space.Make (C)
  module B = (val C.store : Backend.S)

  (* One line a second is enough to show a run is alive; per item it would be the
     expensive part of marking a store whose chunks are already linked. Returns
     whether it fired, so once-a-second work that is not a log line — saving a
     resume cursor — can hang off the same clock. *)
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

  (* {1 The store being collected} *)

  (* The main, and the directory it keeps its objects in. Both spaces live there,
     and opening and closing a run are a rename and an [rm -rf] rather than
     backend operations — which is exactly what {!Backend.caps.gc} claims. *)
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

  (* Reconciling walks every shard there could be, not just the ones the main has:
     only the target knows what it holds, and a shard the main has never had is
     exactly where a target's orphans hide. *)
  let all_shards = List.init Chunk_layout.shards Chunk_layout.shard_name

  let deferred_members () =
    List.filter
      (fun (m : Backend.member) ->
        m.Backend.role = "replica" || m.Backend.role = "backfill")
      C.members

  (* {1 One collector at a time} *)

  (* Two processes stepping one run is not merely wasteful, it loses chunks: both
     resume from the same cursor, so their root lists can partition, and the one
     that finishes its share first starts discarding the old space while the other
     still has roots whose chunks nothing has promoted.

     A lock file rather than another key, because what has to be exclusive is a
     process working *now*. The run marker says a run exists and deliberately
     outlives every process — it is what a later invocation resumes from — so it
     cannot also mean "somebody is on it". [lockf] is released by the kernel when
     the holder dies, which is the whole point: a crashed collection must leave a
     resumable run, not a run nobody may touch.

     ponytail: a lock on the main's own filesystem, so it covers the machine that
     filesystem is local to. Two hosts sharing a main over a network filesystem
     could still both step one run; nothing in this design makes that
     configuration good, and if it ever needs supporting the answer is a lease
     key with a heartbeat, not this. *)
  let lock_path root = Filename.concat root (Space.marker_key ^ ".lock")

  let describe_open_run () =
    let+ run = Space.read_run () in
    match run with
      | None -> ""
      | Some r ->
          Printf.sprintf " (%s, started %.0fs ago)"
            (Chunk_space.string_of_phase r.Chunk_space.phase)
            (Unix.gettimeofday () -. r.Chunk_space.started)

  (* A record lock is held by the *process*, so asking for one twice from within
     the same process succeeds — it merges with the lock already held rather than
     reporting contention. So this process needs its own answer, or two sessions
     here would interleave exactly the way two processes must not. *)
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
    else
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
              Lwt.fail exn)

  (* Closing the descriptor drops the lock. Worth doing even though exiting would:
     a process that collects twice, or does anything else afterwards, must not go
     on holding it. *)
  let drop_lock fd =
    held := false;
    Lwt.catch
      (fun () -> Lwt_unix.close fd)
      (function Unix.Unix_error _ -> Lwt.return_unit | exn -> Lwt.fail exn)

  (* {1 Opening} *)

  (* Move the chunk root aside. A plain rename into a fresh name in the same
     parent, so it is already atomic and needs no [RENAME_EXCHANGE] stunt.

     [chunks/] is not recreated: every writer runs [ensure_parent] before it
     writes, so the space that survives appears when something first lands in it.
     A store with no chunks at all has nothing to rename and nothing to collect. *)
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

  (* {1 Marking} *)

  let parse_version = Versioning.parse ~versions_prefix:C.versions_prefix

  (* A namespace is a name in one of the two directories that can hold something
     referencing a chunk: [manifests/<folder-id>/...] and
     [versions/<folder-id>/...]. Tagged so the two cannot collide in a cursor, and
     so that manifests sort first.

     Encoded and decoded next to each other. A fixed offset written at the other
     end of a file from the tag it takes apart is how the two drift. *)
  let encode which id =
    (match which with `Manifests -> "m" | `Versions -> "v") ^ "/" ^ id

  let decode ns =
    let id = String.sub ns 2 (String.length ns - 2) in
    ((if ns.[0] = 'v' then `Versions else `Manifests), id)

  (* Enumerated a namespace at a time, by reading those two directories, rather
     than by listing both prefixes whole. Listing them whole means walking every
     object in the store before the first chunk is marked — minutes on a large
     domain, outside any budget because it happens before the first step, and paid
     again on every resume, so a budgeted collection would spend most of itself
     re-listing. Two directory reads instead, and the walk of a namespace is part of
     the step that marks it.

     Sorted, so a resume can skip what is done. A namespace created after this read
     is missed and does not need catching: whatever writes it promotes its own
     chunks when it publishes. *)
  let namespaces root =
    let read dir =
      Lwt.catch
        (fun () -> Fs_util.readdir_list (Filename.concat root dir))
        (function Unix.Unix_error _ -> Lwt.return_nil | e -> Lwt.fail e)
    in
    let* manifests = read (dir_of_prefix C.domain_prefix) in
    let+ versions = read (dir_of_prefix C.versions_prefix) in
    List.map (encode `Manifests) manifests
    @ List.map (encode `Versions) versions
    |> List.sort String.compare

  (* The prefix a namespace stands for.

     The trailing slash is not decoration. A backend builds the keys it lists by
     concatenating this onto each entry it finds, so leaving it off yields
     [manifests/<id><hash>] — a key that names nothing. Every lookup through it
     would come back empty, nothing would be promoted, and the collection would then
     discard every chunk in the store. Hence the [`Dir] / [`File] distinction: a
     namespace that is really a single object must not have one. *)
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

  (* {1 Closing} *)

  (* Which shards a phase has to visit, read from the directories rather than
     assumed to be all {!Chunk_layout.shards} of them. A store holding a handful of
     chunks occupies a handful of shards, and walking 4096 of anything to find them
     is work in proportion to the layout instead of to the data.

     Only the main's own spaces are read this way. What a *target* holds is not
     knowable from here, so reconciling asks it about every shard there could be —
     see {!all_shards}. *)
  let shards_in dir =
    Lwt.catch
      (fun () ->
        let+ names = Fs_util.readdir_list dir in
        List.filter Chunk_layout.is_shard_name names)
      (function Unix.Unix_error _ -> Lwt.return_nil | e -> Lwt.fail e)

  (* Abandoning visits the space on its way out; closing visits both, since a shard
     may exist in either. *)
  let from_shards root =
    let+ going = shards_in (from_dir root) in
    List.sort String.compare going

  let live_shards root =
    let* surviving = shards_in (to_dir root) in
    let+ going = shards_in (from_dir root) in
    List.sort_uniq String.compare (surviving @ going)

  (* Discard one shard of the space on its way out, and report what it held that
     the surviving space does not. Nothing here holds more than a shard's worth of
     keys, whatever the store's size. *)
  let close_shard ~main:(module M : Backend.S) ~root shard =
    let* surviving = M.list_prefix ~prefix:(C.chunk_prefix ^ shard ^ "/") () in
    let kept = Hashtbl.create 256 in
    List.iter
      (fun (e : Backend.file_entry) ->
        Hashtbl.replace kept (Filename.basename e.Backend.key) ())
      surviving;
    (* What is reclaimed is counted in chunks. A write left in flight in the space
       going away is discarded with it, but it was never a chunk and saying so would
       overstate what the collection recovered. *)
    let* going = M.list_prefix ~prefix:(Space.from_prefix ^ shard ^ "/") () in
    let reclaimed, bytes =
      List.fold_left
        (fun (n, b) (e : Backend.file_entry) ->
          let name = Filename.basename e.Backend.key in
          if Hashtbl.mem kept name || not (Chunk_layout.is_chunk_key name) then
            (n, b)
          else (n + 1, b + e.Backend.size))
        (0, 0) going
    in
    (* [rm -rf] of the shard rather than a delete per key: every name in it is
       going, and an inode that earned a link under the surviving root survives
       losing this one. *)
    let+ () = Fs_util.rm_rf (Filename.concat (from_dir root) shard) in
    (reclaimed, bytes)

  (* {1 Reconciling the copies} *)

  (* Bringing one shard of one target into line with the settled main.

     Driven by the target's own shards, not the main's: a target holding chunks in
     a shard the main has never had is exactly the drift worth finding, and
     enumerating from the main would be blind to it. That is also why nothing here
     takes a snapshot of the main to compare against — the main is asked directly,
     so there is no window in which a chunk written since the snapshot looks like
     an orphan and gets deleted off a copy that correctly has it.

     Deleting is the whole job for a backfill target: it is filled behind the
     write and being incomplete is its normal condition, so a gap says nothing.
     A replica is meant to be a full copy, so for one a gap is drift and gets
     filled — the same one bit between the two roles that decides whether reads
     may reach it, showing up again. *)
  let reconcile_shard ~main:(module M : Backend.S) ~shard ~slots ~out_of_time
      ~on_step (m : Backend.member) =
    let (module T : Backend.S) = m.Backend.backend in
    let prefix = C.chunk_prefix ^ shard ^ "/" in
    let* held = T.list_prefix ~prefix () in
    let is_replica = m.Backend.role = "replica" in
    if held = [] && not is_replica then Lwt.return (0, 0, true)
    else
      let* mine = M.list_prefix ~prefix () in
      (* Only chunks, on both sides. A target's shard may hold a directory marker,
         or a write some other client has in flight this second — and everything
         here is either compared against the main, deleted for not being there, or
         uploaded. Deleting an unrecognised name off a copy is the worst of those:
         it would take out an upload in progress. *)
      let names entries =
        List.filter_map
          (fun (e : Backend.file_entry) ->
            let n = Filename.basename e.Backend.key in
            if Chunk_layout.is_chunk_key n then Some n else None)
          entries
      in
      let mine = names mine and theirs = names held in
      let set l =
        let h = Hashtbl.create 256 in
        List.iter (fun k -> Hashtbl.replace h k ()) l;
        h
      in
      let on_main = set mine and on_target = set theirs in
      let orphaned =
        List.filter (fun k -> not (Hashtbl.mem on_main k)) theirs
        |> List.map (fun k -> prefix ^ k)
      in
      let* () =
        if orphaned = [] then Lwt.return_unit
        else
          let+ () = T.delete_multi orphaned in
          Log.debug "gc: %s: deleted %d orphan(s) in shard %s" m.Backend.name
            (List.length orphaned) shard
      in
      let missing =
        if is_replica then
          List.filter (fun k -> not (Hashtbl.mem on_target k)) mine
        else []
      in
      (* Filling a replica is the one part of a collection that sends bytes
         anywhere, so it is the part that can run long. Concurrent rather than one
         at a time -- a replica far behind is otherwise a queue of sequential
         round trips, which is what makes a collection look wedged rather than
         busy -- and interruptible between chunks.

         Stopping part-way through a shard loses nothing and needs no finer
         cursor: what has been uploaded stays uploaded, and coming back re-lists
         and finds only what is still missing. So the shard simply reports itself
         unfinished and its cursor is not advanced. *)
      let uploaded = ref 0 in
      let stop = ref false in
      let+ () =
        Lwt_list.iter_p
          (fun k ->
            if !stop then Lwt.return_unit
            else
              Lwt_bounded.use slots (fun () ->
                  if !stop then Lwt.return_unit
                  else if out_of_time () then begin
                    stop := true;
                    Lwt.return_unit
                  end
                  else
                    let* data = M.get ~key:(prefix ^ k) () in
                    let+ () = T.put ~key:(prefix ^ k) ~data () in
                    incr uploaded;
                    on_step ();
                    Log.debug "gc: %s: filled %s" m.Backend.name k))
          missing
      in
      (List.length orphaned, !uploaded, not !stop)

  (* {1 A session} *)

  (* Marking and closing walk the main's shards; reconciling walks every shard
      there could be, because only the target knows which ones it holds. *)
  type work =
    | Mark of string list
    | Keep of string list
    | Close of string list
    | Reconcile of string list

  type session = {
    main : (module Backend.S);
    root : string;
    started : float;
    targets : Backend.member list;
    lock : Lwt_unix.file_descr;
    (* Two pools, and which one to use is decided by nesting depth, not by what is
       being iterated. Whatever this runs several of at once takes from
       [unit_slots]; the per-object work inside one of those takes from
       [item_slots]. One shared pool deadlocks the moment every slot is held by an
       outer unit waiting for an inner one — the trap [Local_backend.list_prefix]
       documents, and one this has fallen into more than once by naming pools after
       the phase that happened to use them. Named for the depth instead, because
       every phase has both. *)
    unit_slots : Lwt_bounded.t;
    item_slots : Lwt_bounded.t;
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
    mutable tallies : member_stats list;
    mutable on_mark :
      namespaces:int -> total:int -> roots:int -> promoted:int -> unit;
    mutable on_close : shards:int -> reclaimed:int -> unit;
    mutable on_reconcile :
      name:string ->
      shards:int ->
      total:int ->
      deleted:int ->
      uploaded:int ->
      unit;
  }

  let phase s =
    match s.work with
      | Mark _ -> "marking"
      | Keep _ -> "abandoning"
      | Close _ -> "closing"
      | Reconcile _ -> "reconciling"
  let done_ s = s.done_
  let total s = s.total
  let release s = drop_lock s.lock

  let cursor s =
    match s.work with
      | Mark (k :: _) | Keep (k :: _) | Close (k :: _) | Reconcile (k :: _) -> k
      | Mark [] | Keep [] | Close [] | Reconcile [] -> ""

  let stats s =
    {
      outcome =
        (if s.finished then Completed
         else Suspended { phase = phase s; cursor = cursor s });
      roots_marked = s.roots_marked;
      chunks_promoted = s.chunks_promoted;
      chunks_reclaimed = s.chunks_reclaimed;
      bytes_reclaimed = s.bytes_reclaimed;
      (* Ordered by configuration, not by whichever target finished first: shards
         run concurrently, so completion order is not stable and a report that
         reshuffles between runs is a report nobody can diff. *)
      members =
        List.filter_map
          (fun (m : Backend.member) ->
            List.find_opt
              (fun (ms : member_stats) -> ms.name = m.Backend.name)
              s.tallies)
          s.targets;
    }

  let status () = Space.read_run ()

  let save s phase cursor =
    Space.write_run { Chunk_space.phase; started = s.started; cursor }

  let start ?concurrency ?(keep = false) () =
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
    (* I/O bound, so what a batch wants is concurrent syscalls, not cores. The
       device's own answer by default, the same figure every other bulk path here
       asks for; 1 makes a run as unobtrusive as it can be. *)
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
        out_of_time = (fun () -> false);
        finished = false;
        work;
        total;
        done_ = 0;
        roots_marked = 0;
        chunks_promoted = 0;
        chunks_reclaimed = 0;
        bytes_reclaimed = 0;
        tallies = [];
        on_mark = (fun ~namespaces:_ ~total:_ ~roots:_ ~promoted:_ -> ());
        on_close = (fun ~shards:_ ~reclaimed:_ -> ());
        on_reconcile =
          (fun ~name:_ ~shards:_ ~total:_ ~deleted:_ ~uploaded:_ -> ());
      }
    in
    (* Whatever state the store is in, continue from there: an interrupted rename
       is redone, an interrupted mark resumes at its cursor, an interrupted close
       at its shard. Nothing here is ambiguous, which is why each phase is
       recorded before the step it names rather than after. *)
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
      (* Abandoning overrides whatever phase the collection had reached, and takes
         no cursor from it: a cursor means something different in each phase, and
         one left by marking or closing says nothing about which shards still need
         keeping. Shards already discarded are gone and cannot be brought back — so
         this keeps what is still there, which is all it can promise. *)
      | _ when keep ->
          let* shards = from_shards root in
          Log.info
            "gc: abandoning the collection of %s, keeping everything left in %d \
             shard(s)"
            C.domain_name (List.length shards);
          let s = fresh (Keep shards) (List.length shards) in
          let+ () = save s Chunk_space.Abandoning "" in
          s
      | Chunk_space.Reconciling ->
          let pending =
            List.filter (fun s -> String.compare s cursor > 0) all_shards
          in
          Log.info "gc: resuming, %d shard(s) left to reconcile"
            (List.length pending);
          Lwt.return (fresh (Reconcile pending) (List.length pending))
      | Chunk_space.Closing ->
          let* shards = live_shards root in
          let pending =
            List.filter (fun s -> String.compare s cursor > 0) shards
          in
          Log.info "gc: resuming, %d shard(s) to close" (List.length pending);
          Lwt.return (fresh (Close pending) (List.length pending))
      (* Once a collection has been called off it stays called off: coming back to
         an [Abandoning] run continues abandoning it rather than quietly resuming a
         collection whoever stopped it did not want. *)
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

  (* Marking one root: read it, and give every chunk it names a link under the
     surviving root. The links go out concurrently within the root, on the same
     budget as the roots themselves — a big file naming thousands of chunks is
     otherwise thousands of serial [link] calls. *)
  let mark_root s key =
    let* chunks = referenced_chunks key in
    let* () =
      Lwt_list.iter_p
        (fun ck -> Lwt_bounded.use s.item_slots (fun () -> Space.promote ck))
        chunks
    in
    s.chunks_promoted <- s.chunks_promoted + List.length chunks;
    s.roots_marked <- s.roots_marked + 1;
    Log.debug "gc: marked %s (%d chunk(s))" key (List.length chunks);
    Lwt.return_unit

  (* One namespace: list it, then mark everything in it. The listing is part of
     the step rather than something done to the whole store up front.

     Roots go out on [root_slots] and the chunks within a root on [chunk_slots] —
     the two pools exist for exactly this nesting, and using one for both levels
     would park every slot on a root waiting for a chunk. Note that the caller must
     not also hold a [root_slots] slot for this whole namespace. *)
  let mark_one s ns =
    let* prefix = prefix_of_namespace s.root ns in
    let* entries = B.list_prefix ~prefix () in
    (* Everything left here is read and parsed, and something that will not parse
       aborts the whole collection with nothing discarded. That is deliberate: the
       alternative is treating an unreadable manifest as referencing nothing, and
       discarding the chunks of the file it names.

       Which is why this skips only what is positively a write in flight, and not
       everything it fails to recognise. Skipping is the *dangerous* direction here
       — a root not marked is a file's chunks reclaimed — whereas in a chunk shard
       it is the safe one, and the same rule in both places is how a first attempt
       at this discarded an entire store. What is unrecognised is still read, and
       still stops the collection loudly, which is a thing somebody can go and
       fix. *)
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
    ignore
      (throttled (fun () ->
           (* Debug, not info: the caller's progress callback is what a terminal
              shows, and saying it twice is worse than once. The phase transitions
              stay at info, so a log kept without [-v] still records that a
              collection ran and what it came to. *)
           Log.debug
             "gc: marked %d/%d namespace(s), %d root(s), %d chunk(s) kept"
             s.done_ s.total s.roots_marked s.chunks_promoted;
           s.on_mark ~namespaces:s.done_ ~total:s.total ~roots:s.roots_marked
             ~promoted:s.chunks_promoted));
    Lwt.return_unit

  (* Accumulated per target across every shard, kept in configuration order. *)
  let record_member s name ~deleted ~uploaded =
    if deleted > 0 || uploaded > 0 then
      let prior =
        List.find_opt (fun (ms : member_stats) -> ms.name = name) s.tallies
      in
      let before =
        Option.value prior ~default:{ name; deleted = 0; uploaded = 0 }
      in
      s.tallies <-
        { before with
          deleted = before.deleted + deleted;
          uploaded = before.uploaded + uploaded;
        }
        :: List.filter (fun (ms : member_stats) -> ms.name <> name) s.tallies

  (* Closing one shard, cursor saved per shard: a shard is a large enough unit
     that one small write against it is nothing. *)
  let close_one s shard =
    let* n, b = close_shard ~main:s.main ~root:s.root shard in
    s.chunks_reclaimed <- s.chunks_reclaimed + n;
    s.bytes_reclaimed <- s.bytes_reclaimed + b;
    s.done_ <- s.done_ + 1;
    let* () = save s Chunk_space.Closing shard in
    ignore
      (throttled (fun () ->
           Log.debug "gc: %d/%d shard(s) closed, %d chunk(s) reclaimed" s.done_
             s.total s.chunks_reclaimed;
           s.on_close ~shards:s.done_ ~reclaimed:s.chunks_reclaimed));
    Lwt.return_unit

  (* {1 Abandoning} *)

  (* Abandoning one shard means giving everything in it a name in the surviving
     space, so that discarding the old space costs nothing. Two ways to do that,
     and the cheap one is usually available.

     A shard the surviving space has nothing of yet is carried over whole: one
     rename in place of a link per chunk. A collection called off early is mostly
     this, marking having reached almost none of the shards, which turns the
     recovery from millions of links into a few thousand renames.

     [rename] onto a directory that exists and holds anything fails, so the shards
     marking did reach fall through to linking. That also settles the race worth
     worrying about: a writer landing a chunk in the shard between the attempt and
     now merely makes the rename fail, and the slower path is correct regardless. *)
  let carry_over s shard =
    let src = Filename.concat (from_dir s.root) shard
    and dst = Filename.concat (to_dir s.root) shard in
    Lwt.catch
      (fun () ->
        (* Counted before it moves, so what gets reported is chunks kept and not
           chunks linked — a carried shard keeps everything in it and would
           otherwise contribute nothing to the total. One directory read against
           the link per chunk it saves. *)
        let* names = Fs_util.readdir_list src in
        let* () = Fs_util.ensure_parent dst in
        let+ () = Lwt_unix_retry.rename src dst in
        (* Counted, not filtered: the rename takes the whole directory, so anything
           else in it comes along. That is where it already was, and picking it out
           would cost the per-file work this exists to avoid — but it is not a chunk
           and must not be reported as one. *)
        Some (List.length (List.filter Chunk_layout.is_chunk_key names)))
      (function
        (* The surviving space already has this shard: link the chunks instead. *)
        | Unix.Unix_error
            ((Unix.ENOTEMPTY | Unix.EEXIST | Unix.ENOTDIR | Unix.EISDIR), _, _)
          ->
            Lwt.return_none
        (* Nothing there to carry: already done, or never existed. *)
        | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return (Some 0)
        | exn -> Lwt.fail exn)

  (* Chunk by chunk, for a shard both spaces hold: read the directory and move each
     name across.

     A move and not a link. Linking leaves the old name behind for the closing
     [rm -rf] to unlink, so every chunk is touched twice — two journalled
     transactions against the inode and both directories, where one will do. What is
     left afterwards is empty directories to remove rather than millions of entries.

     It also needs no [EEXIST] branch. [rename] replaces the destination, which for
     a content-addressed name is no loss because the same name is the same bytes;
     and where the destination is already a link to the same inode, which is what
     marking's promote leaves behind, [rename] does nothing and says it succeeded.

     Nothing here asks whether a chunk is where it was just seen. A [readdir] gives
     the names, so moving is the only thing left to do with each. The parent is
     created once for the shard rather than once per chunk, being the same directory
     every time. *)
  let keep_by_move s shard =
    let src_dir = Filename.concat (from_dir s.root) shard
    and dst_dir = Filename.concat (to_dir s.root) shard in
    let* names = Fs_util.readdir_list src_dir in
    let names = List.filter Chunk_layout.is_chunk_key names in
    let* () = Fs_util.mkdir_p dst_dir in
    let+ () =
      Lwt_list.iter_p
        (fun n ->
          Lwt_bounded.use s.item_slots (fun () ->
              Lwt.catch
                (fun () ->
                  Lwt_unix_retry.rename (Filename.concat src_dir n)
                    (Filename.concat dst_dir n))
                (function
                  (* Gone from under us: a previous attempt at this shard already
                     moved it. *)
                  | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
                  | exn -> Lwt.fail exn)))
        names
    in
    s.chunks_promoted <- s.chunks_promoted + List.length names

  let keep_one s shard =
    let* carried = carry_over s shard in
    let* () =
      match carried with
        | Some n ->
            s.chunks_promoted <- s.chunks_promoted + n;
            Lwt.return_unit
        | None -> keep_by_move s shard
    in
    s.done_ <- s.done_ + 1;
    let* () = save s Chunk_space.Abandoning shard in
    (* [roots:0]: there are no files here, only shards. What the caller prints for
       a collection would read as a second, wrong count of them. *)
    ignore
      (throttled (fun () ->
           Log.debug "gc: kept %d/%d shard(s), %d chunk(s) linked" s.done_
             s.total s.chunks_promoted;
           s.on_mark ~namespaces:s.done_ ~total:s.total ~roots:0
             ~promoted:s.chunks_promoted));
    Lwt.return_unit

  (* Cumulative figures for one target, for reporting mid-phase rather than only
     at the end: a target being filled is the slowest thing a collection does and
     the one a caller most wants to watch. *)
  let tally_of s name =
    match List.find_opt (fun (ms : member_stats) -> ms.name = name) s.tallies with
      | Some ms -> (ms.deleted, ms.uploaded)
      | None -> (0, 0)

  let report_target s name =
    let deleted, uploaded = tally_of s name in
    Log.debug "gc: %s: %d/%d shard(s), %d deleted, %d filled" name s.done_
      s.total deleted uploaded;
    s.on_reconcile ~name ~shards:s.done_ ~total:s.total ~deleted ~uploaded

  (* One shard of every target brought into line with the main. [false] when it
     ran out of time part-way, in which case its cursor is deliberately not saved
     and the shard is done again next time: reconciling a shard is idempotent, so
     repeating one costs a listing and finds less to do. *)
  let reconcile_one s shard =
    let finished = ref true in
    let* () =
      Lwt_list.iter_s
        (fun (m : Backend.member) ->
          let+ deleted, uploaded, complete =
            reconcile_shard ~main:s.main ~shard ~slots:s.item_slots
              ~out_of_time:s.out_of_time
              ~on_step:(fun () ->
                ignore (throttled (fun () -> report_target s m.Backend.name)))
              m
          in
          record_member s m.Backend.name ~deleted ~uploaded;
          if not complete then finished := false;
          if deleted > 0 || uploaded > 0 then report_target s m.Backend.name)
        s.targets
    in
    if not !finished then Lwt.return_false
    else begin
      s.done_ <- s.done_ + 1;
      ignore
        (throttled (fun () ->
             List.iter
               (fun (m : Backend.member) -> report_target s m.Backend.name)
               s.targets));
      Lwt.return_true
    end

  (* Marking done: what is left in the old space is garbage, so switch phases.
     Recorded before the first shard is touched. *)
  let begin_closing s =
    let* shards = live_shards s.root in
    let* () = save s Chunk_space.Closing "" in
    Log.info "gc: marked %d root(s), %d chunk(s) kept; closing %d shard(s)"
      s.roots_marked s.chunks_promoted (List.length shards);
    s.work <- Close shards;
    s.total <- List.length shards;
    s.done_ <- 0;
    Lwt.return_unit

  let begin_reconciling s =
    let* () = save s Chunk_space.Reconciling "" in
    Log.info "gc: %d chunk(s) reclaimed; reconciling %d target(s)"
      s.chunks_reclaimed (List.length s.targets);
    s.work <- Reconcile all_shards;
    s.total <- List.length all_shards;
    s.done_ <- 0;
    Lwt.return_unit

  let finish s =
    let+ () = Space.clear_run () in
    s.finished <- true;
    Log.info "gc: done, %d chunk(s) reclaimed (%d byte(s))" s.chunks_reclaimed
      s.bytes_reclaimed

  (* Everything left of the old root is empty shards and the root itself. *)
  let discard_from_space s = Fs_util.rm_rf (from_dir s.root)

  (* The cursor advances to the largest name done, and only once everything before
     it is done too. Saved per batch rather than per item: one small write against
     a store of a million roots is the difference between noise and a phase of its
     own, and redoing a batch costs a failed link each, promoting being
     idempotent. *)
  let last_of batch =
    List.fold_left (fun acc k -> if k > acc then k else acc) "" batch

  (* One unit at a time, stopping at a boundary when the caller's time is up and
     handing back what was not reached. Each of these units saves its own cursor. *)
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
     discarding. One extra round trip through the loop, and the boundary becomes
     observable — which is what makes the interleaving testable. *)
  let step ?(units = 1) s =
    match s.work with
      | Mark [] ->
          let+ () = begin_closing s in
          `More
      (* Abandoning ends here, rather than going on through the phases a collection
         does. This is chunk-only work: everything the discarded space held now has
         a name in the surviving one, so what is left of it is names and nothing
         else.

         Closing would list both spaces of every shard to count what was reclaimed,
         which an abandonment has defined to be zero. Reconciling would then ask
         every target about all 4096 shards — over a network, for a target on one —
         to find orphans that cannot exist, since nothing was removed from the main
         for them to be orphaned by. Repairing drift a collection did not cause is
         [tsync resync-remote]'s job, and not what someone abandoning one wants. *)
      | Keep [] ->
          let* () = discard_from_space s in
          let+ () = finish s in
          `Done
      (* Nothing left of the old space. The targets are only reconciled when there
         are any; a domain with one store is done here. *)
      | Close [] ->
          let* () = discard_from_space s in
          if s.targets = [] then
            let+ () = finish s in
            `Done
          else
            let+ () = begin_reconciling s in
            `More
      | Reconcile [] ->
          let+ () = finish s in
          `Done
      (* Namespaces one at a time within a batch, the concurrency being inside each
         (its roots, and their chunks). A namespace is already a large unit — a
         listing plus every manifest in it — so a batch of them can run for minutes,
         which is why [out_of_time] is consulted between them rather than only
         between whole steps. Without that, a budget could be overshot by however
         long a batch happens to take. *)
      | Keep shards ->
          let batch, rest = take (max 1 units) shards in
          let* remaining = each s keep_one batch in
          s.work <- Keep (remaining @ rest);
          Lwt.return `More
      | Mark namespaces ->
          let batch, rest = take (max 1 units) namespaces in
          let rec go done_ = function
            | ns :: more when not (s.out_of_time ()) ->
                let* () = mark_one s ns in
                go (ns :: done_) more
            | remaining -> Lwt.return (done_, remaining)
          in
          let* done_, remaining = go [] batch in
          let* () =
            if done_ = [] then Lwt.return_unit
            else save s Chunk_space.Marking (last_of done_)
          in
          s.work <- Mark (remaining @ rest);
          Lwt.return `More
      (* Shards are not batched concurrently: each one deletes a directory and
         then lists every replica, and its cursor is saved as it goes. Overlapping
         them would buy little and make the cursor mean less. *)
      | Close shards ->
          let batch, rest = take (max 1 units) shards in
          let* remaining = each s close_one batch in
          s.work <- Close (remaining @ rest);
          Lwt.return `More
      (* Unlike the other phases, a unit here can stop part-way: filling a replica
         is unbounded work. A shard that did not finish stays at the head of the
         queue rather than being counted done. *)
      (* Shards go out concurrently here, unlike the other phases. A target has to
         be asked about every shard there could be — only it knows what it holds —
         so this is 4096 requests against a store that may be across a network,
         and one at a time that is a quarter of an hour of asking about mostly
         empty prefixes. Bounded by the same pool as the rest of the bulk work, so
         [--concurrency 1] still means one at a time.

         The cursor is a single high-water mark and these finish out of order, so
         it advances only when a whole batch did. A batch with anything left in it
         is redone from the last mark, which costs listings and no correctness:
         reconciling a shard twice finds nothing to do the second time. *)
      | Reconcile shards ->
          let batch, rest = take (max 1 units) shards in
          let unfinished = ref [] in
          let* () =
            Lwt_list.iter_p
              (fun shard ->
                if s.out_of_time () then begin
                  unfinished := shard :: !unfinished;
                  Lwt.return_unit
                end
                else
                  (* [unit_slots]: this is the outer level, and the uploads inside
                     one of these shards take from [item_slots]. *)
                  Lwt_bounded.use s.unit_slots (fun () ->
                      (* Checked again on the way in: a shard can wait a while for a
                         slot, and the answer may have changed since. *)
                      if s.out_of_time () then begin
                        unfinished := shard :: !unfinished;
                        Lwt.return_unit
                      end
                      else
                        let+ finished = reconcile_one s shard in
                        if not finished then unfinished := shard :: !unfinished))
              batch
          in
          let* () =
            if !unfinished = [] then save s Chunk_space.Reconciling (last_of batch)
            else Lwt.return_unit
          in
          s.work <-
            Reconcile (List.sort String.compare !unfinished @ rest);
          Lwt.return `More

  (* {1 Driving it} *)

  let run ?budget ?(units = 256) ?pause ?concurrency ?(keep = false)
      ?(on_open = fun () -> ())
      ?(on_mark = fun ~namespaces:_ ~total:_ ~roots:_ ~promoted:_ -> ())
      ?(on_close = fun ~shards:_ ~reclaimed:_ -> ())
      ?(on_reconcile = fun ~name:_ ~shards:_ ~total:_ ~deleted:_ ~uploaded:_ ->
        ()) () =
    let began = Unix.gettimeofday () in
    let deadline =
      match budget with
        | None -> fun () -> false
        | Some seconds -> fun () -> Unix.gettimeofday () -. began >= seconds
    in
    on_open ();
    let* s = start ?concurrency ~keep () in
    s.out_of_time <- deadline;
    s.on_mark <- on_mark;
    s.on_close <- on_close;
    s.on_reconcile <- on_reconcile;
    let rec loop () =
      let* outcome = step ~units s in
      match outcome with
        | `Done -> Lwt.return (stats s)
        | `More ->
            if deadline () then begin
              (* The budget and what it actually took, because "out of budget"
                 alone cannot be checked against anything: a limit honoured to the
                 second and one overshot twentyfold read identically. *)
              Log.info
                "gc: %.0fs budget spent in %.0fs while %s; run left open"
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
       manifest raises: leaving a run open is fine and resumable, leaving the lock
       held for the life of the process is not. *)
    Lwt.finalize loop (fun () -> release s)

  (* Keep everything: promote every chunk still in the discarded space, then let
     the close find nothing to reclaim. *)
  (* Under the lock like a run: promoting everything while another process
     discards shards is the same race, from the other side. *)
  (* Abandoning is a collection in which every chunk turns out to be live, so it is
     {!run} with the marking phase pointed at the space on its way out. Everything
     that made a collection bearable on a large store — the shard cursor, the
     budget, the pause, the bounded concurrency, the progress — comes along, rather
     than being a loop of its own that had none of it. *)
  let abort ?budget ?units ?pause ?concurrency ?on_open ?on_mark ?on_close
      ?on_reconcile () =
    let* open_ = Space.read_run () in
    match open_ with
      | None -> Lwt.return empty
      | Some _ ->
          run ~keep:true ?budget ?units ?pause ?concurrency ?on_open ?on_mark
            ?on_close ?on_reconcile ()
end
