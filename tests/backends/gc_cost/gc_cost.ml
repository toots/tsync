(* What a collection *costs*, counted, rather than what it leaves behind.

   The scenario tests all check the end state of a store with a handful of chunks,
   and a store that small cannot show the difference between work done once and
   work done per resume. Every defect this file exists for was invisible to them:

   - Enumerating the whole store before the first unit of work. On a real domain
     that is minutes, it happens before any budget can apply, and it used to be
     repaid on every resume — so a budgeted collection spent most of itself
     re-listing and barely advanced.
   - The run marker written through the composite, so every replica and backfill
     target received a copy of it, once per batch, describing a collection that is
     none of their business.

   Both are about counts, not outcomes, so they are what this counts. *)

open Lwt.Syntax

let root = "/tmp/tsync-gc-cost-test"
let main_dir = root ^ "/main"
let replica_dir = root ^ "/replica"
let chunk_prefix = "tsync/testdom/chunks/"
let domain_prefix = "tsync/testdom/manifests/"
let marker_key = Chunk_space.marker_key ~chunk_prefix

type tally = { mutable lists : int; mutable puts : int; mutable markers : int }

let counted () = { lists = 0; puts = 0; markers = 0 }
let main_ops = counted ()
let replica_ops = counted ()

(* Passes everything through and keeps score. [markers] counts writes of the run
   marker specifically: on a copy, any at all is one too many. *)
module Count (B : Backend.S) (T : sig
  val t : tally
end) : Backend.S = struct
  include B

  let list_prefix ?max_keys ~prefix () =
    T.t.lists <- T.t.lists + 1;
    B.list_prefix ?max_keys ~prefix ()

  let put ~key ~data () =
    T.t.puts <- T.t.puts + 1;
    if key = marker_key then T.t.markers <- T.t.markers + 1;
    B.put ~key ~data ()
end

module Main =
  Count
    ((val Local_backend.make ~root:main_dir : Backend.S))
    (struct
      let t = main_ops
    end)

module Replica =
  Count
    ((val Local_backend.make ~root:replica_dir : Backend.S))
    (struct
      let t = replica_ops
    end)

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = domain_prefix
  let chunk_prefix = chunk_prefix
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = "tsync/testdom/cursor"
  let shares_prefix = "tsync/shares/"

  let members =
    [
      Backend.member ~role:"main" ~backend_type:"local" ~local_path:main_dir
        ~name:"main"
        (module Main);
      Backend.member ~role:"replica" ~backend_type:"local"
        ~local_path:replica_dir ~name:"replica"
        (module Replica);
    ]

  (* The real composite, deliberately. A test that hands {!Gc} the main alone
     cannot see anything being fanned out to a copy — which is exactly how the
     marker reaching every replica went unnoticed. *)
  let store =
    Domain_store.make
      ~mains:[{ Domain_store.name = "main"; backend = (module Main) }]
      ~targets:[]
      ~archives:[{ Domain_store.name = "replica"; backend = (module Replica) }]

  let cache_root = root ^ "/cache"
  let data_dir = root ^ "/data"
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 1
  let max_downloads = 1
  let chunk_size = Some 8
  let cache_chunk_size = Some 8
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module G = Gc.Make (C)

let step fmt = Printf.printf ("  " ^^ fmt ^^ "\n")
let case name = Printf.printf "\n=== %s\n" name
let ck n = Printf.sprintf "%03x%013x-%016x" n n n
let folders = 12

let () =
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s && mkdir -p %s %s" root main_dir replica_dir));
  Lwt_main.run
    ((* One folder per namespace, one file in each, one chunk per file: enough
        namespaces that "once" and "once per namespace" are different numbers. *)
     let* () =
       Lwt_list.iter_s
         (fun n ->
           let* () =
             Main.put
               ~key:(chunk_prefix ^ Chunk_layout.relative_path (ck n))
               ~data:"a chunk!" ()
           in
           let m =
             Manifest.make ~name:"f"
               ~h1:(String.make 16 '0')
               ~h2:(String.make 16 '0')
               ~size:8L ~chunk_size:8
               ~chunks:[Manifest.entry_of_key ~index:0 ~size:8 (ck n)]
               ~mtime:0.
           in
           Main.put
             ~key:(Printf.sprintf "%sfolder%02d/deadbeefdeadbeef" domain_prefix n)
             ~data:(Manifest.to_string ~name:"f" m)
             ())
         (List.init folders (fun i -> i + 1))
     in

     case (Printf.sprintf "opening, with %d namespaces to do" folders);
     main_ops.lists <- 0;
     let* s = G.start () in
     step "listings of the store during start: %d" main_ops.lists;
     step "  (the work is found by reading two directories, so this is 0 however";
     step "   many namespaces there are; enumerating up front would make it %d)"
       folders;
     step "namespaces to mark: %d" (G.total s);

     case "marking, one unit at a time";
     main_ops.lists <- 0;
     let* _ = G.step ~units:1 s in
     step "listings for one namespace: %d" main_ops.lists;
     let* () = G.release s in

     case "resuming does not re-find the work";
     main_ops.lists <- 0;
     let* s = G.start () in
     step "listings during a resume's start: %d" main_ops.lists;
     step "namespaces left: %d" (G.total s);
     let* () = G.release s in

     (* Reconciling is the phase that can run long — filling a replica is the only
        part of a collection that sends bytes anywhere — so it is the one whose
        resumability is worth pinning. Driven a step at a time rather than with a
        time limit, which would make the snapshot depend on how fast the machine
        is. *)
     case "reconciling picks up where it stopped";
     let* s = G.start () in
     let rec until phase =
       if G.phase s = phase then Lwt.return_unit
       else
         let* outcome = G.step ~units:1 s in
         match outcome with `Done -> Lwt.return_unit | `More -> until phase
     in
     let* () = until "reconciling" in
     let* _ = G.step ~units:4 s in
     let after_four = G.done_ s in
     step "shards reconciled before stopping: %d" after_four;
     let* () = G.release s in
     let* s = G.start () in
     step "phase on resume: %s" (G.phase s);
     (* [total] is what this session has to do, not what the store has — a resume
        that reported the whole shard space would say nothing about its own
        progress. *)
     step "shards left to reconcile: %d of %d  <- the first %d are not redone"
       (G.total s) Chunk_layout.shards after_four;
     let* () = G.release s in

     case "finishing";
     let* stats = G.run () in
     step "reclaimed %d chunk(s)" stats.Gc.chunks_reclaimed;
     (* Every chunk here is referenced, so a correct collection reclaims none. The
        number that matters is what is left: marking that quietly walks the wrong
        keys promotes nothing, and the close then discards the whole store. A
        collection reporting a tidy success over an emptied store is the worst
        thing this can do, so it is the thing counted last. *)
     let* left = Main.list_prefix ~prefix:chunk_prefix () in
     let left =
       List.filter
         (fun (e : Backend.file_entry) ->
           not (Filename.check_suffix e.Backend.key "/"))
         left
     in
     step "chunks still on the main: %d of %d" (List.length left) folders;
     (* The replica started empty, so finishing across two sessions has to have
        filled it — an interruptible fill that quietly drops what it did not get to
        would look identical above. *)
     let* filled = Replica.list_prefix ~prefix:chunk_prefix () in
     let filled =
       List.filter
         (fun (e : Backend.file_entry) ->
           not (Filename.check_suffix e.Backend.key "/"))
         filled
     in
     step "chunks on the replica: %d of %d" (List.length filled) folders;

     (* Abandoning is the collection machinery with everything treated as live, so
        it is resumable the same way — and the thing that has to hold is that it
        resumes as an abandonment. Coming back to one and quietly collecting
        instead would discard exactly what somebody stopped it to keep. *)
     case "an interrupted abandonment stays an abandonment";
     let* s = G.start () in
     let* _ = G.step ~units:1 s in
     step "started collecting, phase: %s" (G.phase s);
     let* () = G.release s in
     let* s = G.start ~keep:true () in
     step "changed our mind, phase: %s" (G.phase s);
     let* _ = G.step ~units:1 s in
     let* () = G.release s in
     let* s = G.start () in
     step "resumed with a plain start, phase: %s  <- not \"marking\""
       (G.phase s);
     let* () = G.release s in
     (* Abandoning is chunk-only work on the main, so the copies should not be
        touched at all. Nothing was removed for them to have orphaned, and asking
        each about all 4096 shards — over a network, for a target on one — to find
        orphans that cannot exist is a long detour bolted onto a recovery. *)
     replica_ops.lists <- 0;
     let* kept = G.abort () in
     step "finished abandoning: %d chunk(s) kept" kept.Gc.chunks_promoted;
     step "listings of the replica during the abandonment: %d" replica_ops.lists;
     let* left = Main.list_prefix ~prefix:chunk_prefix () in
     let left =
       List.filter
         (fun (e : Backend.file_entry) ->
           not (Filename.check_suffix e.Backend.key "/"))
         left
     in
     step "chunks still on the main: %d of %d" (List.length left) folders;

     (* The pool discipline, which is the thing here most easily got wrong: shards
        run concurrently and each may upload, so the outer level and the inner one
        have to draw from different pools. Sharing one, every slot ends up held by a
        shard waiting to upload and nothing proceeds.

        Showing that takes contention, and contention takes more shards wanting to
        upload at once than there are slots — hence emptying the replica first and
        setting the concurrency below the number of shards involved. With a slot per
        shard to spare, a shared pool looks perfectly healthy, which is how this
        went unnoticed twice. *)
     case "many shards uploading at once, with fewer slots than shards";
     let* held = Replica.list_prefix ~prefix:chunk_prefix () in
     let* () =
       Replica.delete_multi
         (List.filter_map
            (fun (e : Backend.file_entry) ->
              if Filename.check_suffix e.Backend.key "/" then None
              else Some e.Backend.key)
            held)
     in
     let* _ = G.run ~concurrency:2 () in
     let* refilled = Replica.list_prefix ~prefix:chunk_prefix () in
     let refilled =
       List.filter
         (fun (e : Backend.file_entry) ->
           not (Filename.check_suffix e.Backend.key "/"))
         refilled
     in
     step "emptied the replica, refilled it with 2 slots and %d shards" folders;
     step "chunks back on the replica: %d of %d" (List.length refilled) folders;

     case "the copies were told nothing about the collection";
     step "run markers written to the replica: %d" replica_ops.markers;
     let* leftover = Replica.get_opt ~key:marker_key () in
     step "replica holds a run marker afterwards: %b" (leftover <> None);
     Lwt.return_unit)
