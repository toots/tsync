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

  (* Every object that can reference a chunk: live manifests and folder markers,
     and the versions that survived {!Expire}. Sorted as one sequence — a cursor
     is a key, and "manifests" sorts before "versions" anyway. *)
  let list_roots () =
    let* manifests = B.list_prefix ~prefix:C.domain_prefix () in
    let+ versions = B.list_prefix ~prefix:C.versions_prefix () in
    List.map (fun (e : Backend.file_entry) -> e.Backend.key) manifests
    @ List.map (fun (e : Backend.file_entry) -> e.Backend.key) versions
    |> List.sort String.compare

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

  (* The shards that actually exist, either space, by reading the two directories
     rather than walking all {!Chunk_layout.shards} of a space that may hold
     nothing. On a small store that is the difference between a handful of
     listings per replica and 4096 of them, and a listing of a remote replica is a
     request.

     ponytail: a replica holding chunks in a shard the main has never had is not
     reached, since nothing here enumerates the replica's own shards. Those are
     orphans from before this ran and stay orphans. Enumerate the members too if
     it ever matters; it costs a full listing of each. *)
  let live_shards root =
    let read dir =
      Lwt.catch
        (fun () -> Fs_util.readdir_list dir)
        (function Unix.Unix_error _ -> Lwt.return_nil | e -> Lwt.fail e)
    in
    let* surviving = read (to_dir root) in
    let+ going = read (from_dir root) in
    List.sort_uniq String.compare (surviving @ going)
    |> List.filter (fun s -> String.length s = Chunk_layout.fanout)

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
    let* going = M.list_prefix ~prefix:(Space.from_prefix ^ shard ^ "/") () in
    let reclaimed, bytes =
      List.fold_left
        (fun (n, b) (e : Backend.file_entry) ->
          if Hashtbl.mem kept (Filename.basename e.Backend.key) then (n, b)
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
  let reconcile_shard ~main:(module M : Backend.S) ~shard (m : Backend.member) =
    let (module T : Backend.S) = m.Backend.backend in
    let prefix = C.chunk_prefix ^ shard ^ "/" in
    let* held = T.list_prefix ~prefix () in
    let is_replica = m.Backend.role = "replica" in
    if held = [] && not is_replica then Lwt.return (0, 0)
    else
      let* mine = M.list_prefix ~prefix () in
      let names entries =
        List.filter_map
          (fun (e : Backend.file_entry) ->
            let k = e.Backend.key in
            if String.length k > 0 && k.[String.length k - 1] = '/' then None
            else Some (Filename.basename k))
          entries
      in
      let mine = names mine and theirs = names held in
      let on_main = Hashtbl.create 256 in
      List.iter (fun k -> Hashtbl.replace on_main k ()) mine;
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
      let+ uploaded =
        if not is_replica then Lwt.return 0
        else begin
          let theirs_set = Hashtbl.create 256 in
          List.iter (fun k -> Hashtbl.replace theirs_set k ()) theirs;
          let missing =
            List.filter (fun k -> not (Hashtbl.mem theirs_set k)) mine
          in
          let+ () =
            Lwt_list.iter_s
              (fun k ->
                let* data = M.get ~key:(prefix ^ k) () in
                let+ () = T.put ~key:(prefix ^ k) ~data () in
                Log.debug "gc: %s: filled %s" m.Backend.name k)
              missing
          in
          List.length missing
        end
      in
      (List.length orphaned, uploaded)

  (* {1 A session} *)

  (* Marking and closing walk the main's shards; reconciling walks every shard
      there could be, because only the target knows which ones it holds. *)
  type work =
    | Mark of string list
    | Close of string list
    | Reconcile of string list

  type session = {
    main : (module Backend.S);
    root : string;
    started : float;
    targets : Backend.member list;
    lock : Lwt_unix.file_descr;
    (* Two pools, not one. A root holds a [root_slots] slot for as long as it
       takes, and inside that asks for a [chunk_slots] slot per link — one shared
       pool would deadlock the moment every slot was held by a root waiting to
       promote, which is the trap [Local_backend.list_prefix] documents. Distinct
       pools cannot: a chunk slot is only ever held by a link, which finishes. *)
    root_slots : Lwt_bounded.t;
    chunk_slots : Lwt_bounded.t;
    mutable finished : bool;
    mutable work : work;
    mutable total : int;
    mutable done_ : int;
    mutable roots_marked : int;
    mutable chunks_promoted : int;
    mutable chunks_reclaimed : int;
    mutable bytes_reclaimed : int;
    mutable tallies : member_stats list;
    mutable on_mark : roots:int -> total:int -> promoted:int -> unit;
    mutable on_close : shards:int -> reclaimed:int -> unit;
    mutable on_reconcile : name:string -> deleted:int -> uploaded:int -> unit;
  }

  let phase s =
    match s.work with
      | Mark _ -> "marking"
      | Close _ -> "closing"
      | Reconcile _ -> "reconciling"
  let done_ s = s.done_
  let total s = s.total
  let release s = drop_lock s.lock

  let cursor s =
    match s.work with
      | Mark (k :: _) | Close (k :: _) | Reconcile (k :: _) -> k
      | Mark [] | Close [] | Reconcile [] -> ""

  let stats s =
    {
      outcome =
        (if s.finished then Completed
         else Suspended { phase = phase s; cursor = cursor s });
      roots_marked = s.roots_marked;
      chunks_promoted = s.chunks_promoted;
      chunks_reclaimed = s.chunks_reclaimed;
      bytes_reclaimed = s.bytes_reclaimed;
      members = List.rev s.tallies;
    }

  let status () = Space.read_run ()

  let save s phase cursor =
    Space.write_run { Chunk_space.phase; started = s.started; cursor }

  let start ?concurrency () =
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
            Option.value caps.Backend.max_concurrency ~default:8
    in
    let fresh work total =
      {
        main;
        root;
        started;
        targets = deferred_members ();
        lock;
        root_slots = Lwt_bounded.create ~max:max_slots ();
        chunk_slots = Lwt_bounded.create ~max:max_slots ();
        finished = false;
        work;
        total;
        done_ = 0;
        roots_marked = 0;
        chunks_promoted = 0;
        chunks_reclaimed = 0;
        bytes_reclaimed = 0;
        tallies = [];
        on_mark = (fun ~roots:_ ~total:_ ~promoted:_ -> ());
        on_close = (fun ~shards:_ ~reclaimed:_ -> ());
        on_reconcile = (fun ~name:_ ~deleted:_ ~uploaded:_ -> ());
      }
    in
    (* Whatever state the store is in, continue from there: an interrupted rename
       is redone, an interrupted mark resumes at its cursor, an interrupted close
       at its shard. Nothing here is ambiguous, which is why each phase is
       recorded before the step it names rather than after. *)
    match phase with
      | Chunk_space.Reconciling ->
          let pending =
            List.filter (fun s -> String.compare s cursor > 0) all_shards
          in
          Log.info "gc: resuming, %d shard(s) left to reconcile"
            (List.length pending);
          Lwt.return (fresh (Reconcile pending) (List.length all_shards))
      | Chunk_space.Closing ->
          let* shards = live_shards root in
          let pending =
            List.filter (fun s -> String.compare s cursor > 0) shards
          in
          Log.info "gc: resuming, %d shard(s) to close" (List.length pending);
          Lwt.return (fresh (Close pending) (List.length shards))
      | Chunk_space.Opening | Chunk_space.Marking ->
          if existing = None then
            Log.info "gc: opening a collection of %s" C.domain_name;
          let s = fresh (Mark []) 0 in
          let* () = save s Chunk_space.Opening "" in
          let* () = open_space root in
          let* () = save s Chunk_space.Marking cursor in
          let* roots = list_roots () in
          let pending =
            List.filter (fun k -> String.compare k cursor > 0) roots
          in
          Log.info "gc: %d root(s) to mark" (List.length pending);
          s.work <- Mark pending;
          s.total <- List.length pending;
          Lwt.return s

  (* Marking one root: read it, and give every chunk it names a link under the
     surviving root. The links go out concurrently within the root, on the same
     budget as the roots themselves — a big file naming thousands of chunks is
     otherwise thousands of serial [link] calls. *)
  let mark_one s key =
    let* chunks = referenced_chunks key in
    let* () =
      Lwt_list.iter_p
        (fun ck -> Lwt_bounded.use s.chunk_slots (fun () -> Space.promote ck))
        chunks
    in
    s.chunks_promoted <- s.chunks_promoted + List.length chunks;
    s.roots_marked <- s.roots_marked + 1;
    s.done_ <- s.done_ + 1;
    Log.debug "gc: marked %s (%d chunk(s))" key (List.length chunks);
    ignore
      (throttled (fun () ->
           (* Debug, not info: the caller's progress callback is what a terminal
              shows, and saying it twice is worse than once. The phase transitions
              stay at info, so a log kept without [-v] still records that a
              collection ran and what it came to. *)
           Log.debug "gc: marked %d/%d root(s), %d chunk(s) kept" s.done_ s.total
             s.chunks_promoted;
           s.on_mark ~roots:s.done_ ~total:s.total ~promoted:s.chunks_promoted));
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

  (* One shard of every target brought into line with the main. *)
  let reconcile_one s shard =
    let* () =
      Lwt_list.iter_s
        (fun (m : Backend.member) ->
          let+ deleted, uploaded = reconcile_shard ~main:s.main ~shard m in
          record_member s m.Backend.name ~deleted ~uploaded;
          if deleted > 0 || uploaded > 0 then
            s.on_reconcile ~name:m.Backend.name ~deleted ~uploaded)
        s.targets
    in
    s.done_ <- s.done_ + 1;
    let* () = save s Chunk_space.Reconciling shard in
    ignore
      (throttled (fun () ->
           Log.debug "gc: reconciled %d/%d shard(s)" s.done_ s.total;
           s.on_close ~shards:s.done_ ~reclaimed:s.chunks_reclaimed));
    Lwt.return_unit

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

  (* The cursor advances by whole batch, to the largest key in it, and only once
     every root in the batch is done. A batch runs concurrently, so "the last root
     finished" is not the largest one and saving that would strand the roots that
     had not finished yet. Per batch it is also one small write instead of one per
     root, which on a store of a million roots is the difference between noise and
     a phase of its own. *)
  let last_of batch =
    List.fold_left (fun acc k -> if k > acc then k else acc) "" batch

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
      | Mark roots ->
          let batch, rest = take (max 1 units) roots in
          let* () =
            Lwt_list.iter_p
              (fun key ->
                Lwt_bounded.use s.root_slots (fun () -> mark_one s key))
              batch
          in
          let* () = save s Chunk_space.Marking (last_of batch) in
          s.work <- Mark rest;
          Lwt.return `More
      (* Shards are not batched concurrently: each one deletes a directory and
         then lists every replica, and its cursor is saved as it goes. Overlapping
         them would buy little and make the cursor mean less. *)
      | Close shards ->
          let batch, rest = take (max 1 units) shards in
          let* () = Lwt_list.iter_s (close_one s) batch in
          s.work <- Close rest;
          Lwt.return `More
      | Reconcile shards ->
          let batch, rest = take (max 1 units) shards in
          let* () = Lwt_list.iter_s (reconcile_one s) batch in
          s.work <- Reconcile rest;
          Lwt.return `More

  (* {1 Driving it} *)

  let run ?budget ?(units = 256) ?pause ?concurrency ?(on_open = fun () -> ())
      ?(on_mark = fun ~roots:_ ~total:_ ~promoted:_ -> ())
      ?(on_close = fun ~shards:_ ~reclaimed:_ -> ())
      ?(on_reconcile = fun ~name:_ ~deleted:_ ~uploaded:_ -> ()) () =
    let deadline =
      match budget with
        | None -> fun () -> false
        | Some seconds ->
            let stop = Unix.gettimeofday () +. seconds in
            fun () -> Unix.gettimeofday () >= stop
    in
    on_open ();
    let* s = start ?concurrency () in
    s.on_mark <- on_mark;
    s.on_close <- on_close;
    s.on_reconcile <- on_reconcile;
    let rec loop () =
      let* outcome = step ~units s in
      match outcome with
        | `Done -> Lwt.return (stats s)
        | `More ->
            if deadline () then begin
              Log.info "gc: out of budget while %s; run left open" (phase s);
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
  let abort ?(on_mark = fun ~roots:_ ~total:_ ~promoted:_ -> ()) () =
    let* main, root = collector () in
    let* lock = take_lock root in
    Lwt.finalize
      (fun () ->
        let* existing = Space.read_run () in
        match existing with
          | None -> Lwt.return empty
          | Some _ ->
              let (module M : Backend.S) = main in
              Log.info "gc: abandoning the collection of %s, keeping everything"
                C.domain_name;
              let* going = M.list_prefix ~prefix:Space.from_prefix () in
              let total = List.length going in
              let done_ = ref 0 in
              let* () =
                Lwt_list.iter_s
                  (fun (e : Backend.file_entry) ->
                    let+ () = Space.promote (Filename.basename e.Backend.key) in
                    incr done_;
                    ignore
                      (throttled (fun () ->
                           Log.debug "gc: kept %d/%d chunk(s)" !done_ total;
                           on_mark ~roots:!done_ ~total ~promoted:!done_)))
                  going
              in
              let* () = Fs_util.rm_rf (from_dir root) in
              let+ () = Space.clear_run () in
              Log.info "gc: abandoned, %d chunk(s) kept" total;
              { empty with chunks_promoted = total })
      (fun () -> drop_lock lock)
end
