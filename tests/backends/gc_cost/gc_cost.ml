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
   - Closing asking every copy about every shard there could be, so a domain
     holding twelve chunks paid 4096 round trips per copy to find them.

   All three are about counts, not outcomes, so they are what this counts. *)

open Lwt.Syntax
open Check

let root = "/tmp/tsync-gc-cost-test"
let main_dir = root ^ "/main"
let replica_dir = root ^ "/replica"
let chunk_prefix = "tsync/testdom/chunks/"
let domain_prefix = "tsync/testdom/manifests/"
let marker_key = Chunk_space.marker_key ~chunk_prefix

type tally = {
  mutable lists : int;
  mutable jobs : int;
  mutable puts : int;
  mutable markers : int;
  mutable heads : int;
  mutable copies : int;
}

let counted () =
  { lists = 0; jobs = 0; puts = 0; markers = 0; heads = 0; copies = 0 }

let main_ops = counted ()
let replica_ops = counted ()

(* Passes everything through and keeps score. [markers] counts writes of the run
   marker specifically: on a copy, any at all is one too many. *)
module Count
    (B : Backend.S)
    (T : sig
      val t : tally
    end) : Backend.S = struct
  include B

  (* Counted apart from [lists], which stands for walking a copy's chunk space:
     asking whether any delete request is still sitting there is one round trip
     a run, not one a shard, and conflating the two would hide either. *)
  let list_prefix ?max_keys ~prefix () =
    if prefix = Chunk_layout.gc_jobs_prefix ~chunk_prefix then
      T.t.jobs <- T.t.jobs + 1
    else T.t.lists <- T.t.lists + 1;
    B.list_prefix ?max_keys ~prefix ()

  let put ~key ~data () =
    T.t.puts <- T.t.puts + 1;
    if key = marker_key then T.t.markers <- T.t.markers + 1;
    B.put ~key ~data ()

  let head_opt ~key () =
    T.t.heads <- T.t.heads + 1;
    B.head_opt ~key ()

  (* [copies] is the hard-link requirement, counted. Marking used to promote a
     chunk through here, and [Local_backend.copy] answers a filesystem with no
     links to give by rewriting the body — so on exFAT, on an Android shared
     volume, on several network mounts, a collection rewrote the whole live set
     while reporting itself supported. Promotion is a [rename] now and nothing on
     that path may come back through here. *)
  let copy ~src_key ~dst_key () =
    T.t.copies <- T.t.copies + 1;
    B.copy ~src_key ~dst_key ()
end

module Main =
  Count
    ((val Backend.make ~backend_type:"local"
            ~get_field:(fun _ -> Some main_dir)
            ()
         : Backend.S))
    (struct
      let t = main_ops
    end)

module Replica =
  Count
    ((val Backend.make ~backend_type:"local"
            ~get_field:(fun _ -> Some replica_dir)
            ()
         : Backend.S))
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
module Space = Chunk_space.Make (C)

let ck n = Printf.sprintf "%03x%013x-%016x" n n n
let folders = 12

(* Counted by what a chunk is named, so a write left in flight is never mistaken
   for one. *)
let count_chunks entries =
  List.length
    (List.filter
       (fun (e : Backend.file_entry) ->
         Chunk_layout.is_chunk_key (Filename.basename e.Backend.key))
       entries)

let count_strays entries = List.length entries - count_chunks entries

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
               ~data:(Bigstring.of_string "a chunk!")
               ()
           in
           let m =
             Manifest.make ~name:"f" ~h1:(String.make 16 '0')
               ~h2:(String.make 16 '0') ~size:8L ~chunk_size:8
               ~chunks:[Manifest.entry_of_key ~index:0 ~size:8 (ck n)]
               ~mtime:0.
           in
           Main.put
             ~key:
               (Printf.sprintf "%sfolder%02d/deadbeefdeadbeef" domain_prefix n)
             ~data:(Bigstring.of_string (Manifest.to_string ~name:"f" m))
             ())
         (List.init folders (fun i -> i + 1))
     in

     case (Printf.sprintf "opening, with %d namespaces to do" folders);
     main_ops.lists <- 0;
     let* s = G.start () in
     step "listings of the store during start: %d" main_ops.lists;
     step
       "  (the work is found by reading two directories, so this is 0 however";
     step "   many namespaces there are; enumerating up front would make it %d)"
       folders;
     step "namespaces to mark: %d" (G.total s);

     case "marking, one unit at a time";
     main_ops.lists <- 0;
     main_ops.heads <- 0;
     let* _ = G.step ~units:1 s in
     step "listings for one namespace: %d" main_ops.lists;
     (* Promoting a chunk is one rename and nothing else. It used to ask first
        whether the chunk was in the old space, which the rename answers by
        succeeding or not — a stat per chunk, over the millions of them a
        collection promotes. *)
     step "chunks asked about before being promoted: %d" main_ops.heads;
     (* One saved cursor per namespace, so an interruption gives back at most the
        namespace in flight. Saved per batch instead — [units] namespaces, each a
        folder's worth of manifests — an interruption threw away hours of relinking,
        and the cursor sat empty meanwhile saying nothing had been done. *)
     main_ops.markers <- 0;
     let* _ = G.step ~units:4 s in
     step "cursors saved while marking 4 namespace(s): %d" main_ops.markers;
     let* () = G.release s in

     case "resuming does not re-find the work";
     main_ops.lists <- 0;
     let* s = G.start () in
     step "listings during a resume's start: %d" main_ops.lists;
     step "namespaces left: %d" (G.total s);
     let* () = G.release s in

     (* The phase this file exists for as much as for the marking counts: closing
        used to walk every shard there could be on every copy, so its cost was the
        shard space's and not the store's. What it must be now is the shards the
        main actually holds, whatever else the domain is configured with. *)
     case "closing asks the copies nothing";
     let* s = G.start () in
     let rec until phase =
       if G.phase s = phase then Lwt.return_unit
       else
         let* outcome = G.step ~units:1 s in
         match outcome with `Done -> Lwt.return_unit | `More -> until phase
     in
     let* () = until "closing" in
     step "shards to close: %d of a possible %d" (G.total s) Chunk_layout.shards;
     replica_ops.lists <- 0;
     main_ops.lists <- 0;
     main_ops.heads <- 0;
     let* _ = G.step ~units:4 s in
     let after_four = G.done_ s in
     step "shards closed before stopping: %d" after_four;
     (* One listing a shard, of the shard on its way out. A copy is written to,
        never read — asking it what it holds is the 4096 round trips this stopped
        doing. *)
     step "listings of the main while closing 4 shard(s): %d" main_ops.lists;
     step "listings of the replica while closing 4 shard(s): %d"
       replica_ops.lists;
     (* What survived is asked after by name, and only for whatever the outgoing
        shard still holds. Listing the surviving shard instead read its several
        hundred entries to adjudicate the handful marking left behind, which on a
        spinning main was the whole phase. Nothing here is garbage, so the
        question is never reached. *)
     step "chunks asked after in the surviving space: %d" main_ops.heads;
     let* () = G.release s in
     let* s = G.start () in
     step "phase on resume: %s" (G.phase s);
     (* [total] is what this session has to do, not what the store has — a resume
        that reported everything again would say nothing about its own progress. *)
     step "shards left to close: %d  <- the first %d are not redone" (G.total s)
       after_four;
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
     step "chunks still on the main: %d of %d" (count_chunks left) folders;
     (* The replica started empty and stays empty: a collection deletes on the
        copies and never writes to them. Filling one is [tsync mirror]'s job. *)
     let* copied = Replica.list_prefix ~prefix:chunk_prefix () in
     step "chunks on the replica: %d  <- a collection never fills one"
       (count_chunks copied);

     (* Abandoning is the collection machinery with everything treated as live, so
        it is resumable the same way — and the thing that has to hold is that it
        resumes as an abandonment. Coming back to one and quietly collecting
        instead would discard exactly what somebody stopped it to keep. *)
     case "an interrupted abandonment stays an abandonment";
     let* s = G.start () in
     let* _ = G.step ~units:1 s in
     step "started collecting, phase: %s" (G.phase s);
     (* One write in flight per shard, of the shape the local driver leaves behind,
        planted after the space was moved aside. Abandoning must not count these as
        chunks kept — and the shards it links rather than renames must not carry
        them across. Both filters show up in the one number: without them the count
        below doubles. *)
     let from_dir =
       Filename.concat main_dir
         (Filename.chop_suffix (Chunk_space.from_prefix ~chunk_prefix) "/")
     in
     let* strays =
       let+ shards = Fs_util.readdir_list from_dir in
       List.length shards
     in
     ignore
       (Sys.command
          (Printf.sprintf
             "for d in %s/*/; do : > \"$d/deadbeefdeadbeef.$$.1.tmp\"; done"
             (Filename.quote from_dir)));
     step "planted a write in flight in each of %d shard(s)" strays;
     (* A chunk in a shard the surviving space already has, but under a name it does
        not. Marking promoted one chunk into shard 001, so that shard takes neither
        the whole-directory rename nor the found-already-there path — it is the one
        case where abandoning has to move something, and the only one that moves
        data. Without this the moving branch is never run by any test. *)
     (* Several, so the shard is lopsided enough to take the cheaper way round:
        emptying the one chunk out of the surviving space and renaming the whole
        directory in, rather than moving five across. One planted chunk would leave
        the two sides even and exercise only the other branch. *)
     let orphans =
       List.init 5 (fun i -> Printf.sprintf "%03x%013x-%016x" 1 (900 + i) i)
     in
     List.iter
       (fun k ->
         ignore
           (Sys.command
              (Printf.sprintf "printf 'a chunk!' > %s"
                 (Filename.quote
                    (Filename.concat from_dir (Chunk_layout.relative_path k))))))
       orphans;
     step
       "planted %d chunk(s) only the old space has, in a shard the new one \
        holds"
       (List.length orphans);
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
     replica_ops.jobs <- 0;
     let* kept = G.abort () in
     step "finished abandoning: %d chunk(s) kept" kept.Gc.chunks_promoted;
     step "listings of the replica during the abandonment: %d" replica_ops.lists;
     (* Once, when the run opens. What it looks for is a request an earlier
        collection left unconsumed, which nothing else would ever mention: the
        keys it names are already gone from the main. *)
     step "asked whether the replica has delete requests outstanding: %d"
       replica_ops.jobs;
     let* left = Main.list_prefix ~prefix:chunk_prefix () in
     step "chunks still on the main: %d of %d" (count_chunks left) folders;
     (* A shard renamed as a directory brings whatever else was in it, the writes in
        flight included: picking them out would cost the per-file work the rename
        exists to avoid. They are where they already were, nothing names them, and the
        next collection discards them with everything else unreferenced. What matters
        is that they were never counted as chunks kept.

        Which makes this the number that watches the cheap path. A shard moved chunk
        by chunk filters its stray out, so one short of the planted count means a
        shard did not take the directory rename — and the lopsided shard only gets
        there by having the surviving space emptied first.

        Worth watching, because that emptying quietly did nothing at first: it renamed
        each name down onto its own hard link, which POSIX defines as a no-op, so the
        directory stayed as full as it was and every shard fell back. Chunks kept was
        identical and every test passed. This was the only number that moved. *)
     step "writes in flight carried along by a renamed shard: %d of %d"
       (count_strays left) strays;
     let* arrived =
       Lwt_list.filter_s
         (fun k ->
           let+ h =
             Main.head_opt ~key:(chunk_prefix ^ Chunk_layout.relative_path k) ()
           in
           h <> None)
         orphans
     in
     step "chunks only the old space had, now in the new one: %d of %d"
       (List.length arrived) (List.length orphans);

     (* The pool discipline, which is the thing here most easily got wrong: a
        namespace runs its roots concurrently and each root promotes its chunks
        concurrently, so the outer level and the inner one have to draw from
        different pools. Sharing one, every slot ends up held by a root waiting on
        a chunk and nothing proceeds — a hang, not a wrong answer, which is why it
        went unnoticed twice.

        Showing that takes contention, and contention takes more roots wanting to
        promote at once than there are slots: hence a namespace of [wide] files,
        each naming [wide] chunks, collected with two slots. With a slot per root
        to spare, a shared pool looks perfectly healthy. *)
     case "many roots promoting at once, with fewer slots than roots";
     let wide = 8 in
     let wide_ck f i = Printf.sprintf "%03x%013x-%016x" (0x100 + f) i i in
     let* () =
       Lwt_list.iter_s
         (fun f ->
           let chunks = List.init wide (fun i -> wide_ck f i) in
           let* () =
             Lwt_list.iter_s
               (fun k ->
                 Main.put
                   ~key:(chunk_prefix ^ Chunk_layout.relative_path k)
                   ~data:(Bigstring.of_string "a chunk!")
                   ())
               chunks
           in
           let m =
             Manifest.make ~name:"f" ~h1:(String.make 16 '0')
               ~h2:(String.make 16 '0')
               ~size:(Int64.of_int (8 * wide))
               ~chunk_size:8
               ~chunks:
                 (List.mapi
                    (fun i k -> Manifest.entry_of_key ~index:i ~size:8 k)
                    chunks)
               ~mtime:0.
           in
           Main.put
             ~key:(Printf.sprintf "%swide/%016x" domain_prefix f)
             ~data:(Bigstring.of_string (Manifest.to_string ~name:"f" m))
             ())
         (List.init wide (fun i -> i))
     in
     let* _ = G.run ~concurrency:2 () in
     let* after = Main.list_prefix ~prefix:chunk_prefix () in
     step "collected %d root(s) of %d chunk(s) each with 2 slots" wide wide;
     step "chunks on the main: %d of %d" (count_chunks after)
       (folders + (wide * wide));

     (* A collection abandoned under an older build left the old space's directories
        behind, below its cursor, for a sweep at the end to remove. Those shards are
        work like any other and go round the loop again — which has to keep their
        chunks before removing anything, not merely delete what it finds. Forced here
        by putting the cursor past every shard, so the first pass does nothing at all
        and only the sweep is left. *)
     case "shards the cursor skipped are swept up, chunks and all";
     let* s = G.start () in
     let* () = G.release s in
     let* () =
       Space.write_run
         { Chunk_space.phase = Abandoning; started = 0.; cursor = "fff" }
     in
     let* swept = G.abort () in
     step "kept while sweeping: %d chunk(s)" swept.Gc.chunks_promoted;
     let* left = Main.list_prefix ~prefix:chunk_prefix () in
     step "chunks on the main afterwards: %d of %d" (count_chunks left)
       (folders + (wide * wide));
     let* run = G.status () in
     step "collection closed: %b" (run = None);

     (* Counted over every collection and abandonment this file has run, not one
        of them: a single [copy] anywhere on the path is the requirement coming
        back. *)
     case "collecting asks the filesystem for nothing but rename";
     step "calls to Backend.copy across every run above: %d" main_ops.copies;

     case "the copies were told nothing about the collection";
     step "run markers written to the replica: %d" replica_ops.markers;
     let* leftover = Replica.get_opt ~key:marker_key () in
     step "replica holds a run marker afterwards: %b" (leftover <> None);
     Lwt.return_unit)
