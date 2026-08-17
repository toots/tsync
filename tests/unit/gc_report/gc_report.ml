(* What a collection told its caller, against what it returned.

   [tsync status] renders a running gc from the progress callbacks, and the
   command prints its summary from {!Gc.stats}. Those are two accounts of one
   run, and the only thing keeping them together is that the callbacks end on
   the figures the stats carry.

   They are throttled to about a second, which is what makes a small domain the
   case that matters: a phase shorter than the interval reports nothing at all,
   and a phase whose first item lands inside another's interval reports nothing
   until a second has gone by. Every store here is small enough that the whole
   run fits inside one interval, so a report that only arrives on the clock
   never arrives. *)

open Lwt.Syntax
open Check

let root = "/tmp/tsync-gc-report-test"
let main_dir = root ^ "/main"
let chunk_prefix = "tsync/testdom/chunks/"
let domain_prefix = "tsync/testdom/manifests/"

module Main =
  (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some main_dir)
      : Backend.S)

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
    ]

  let store =
    Domain_store.make
      ~mains:[{ Domain_store.name = "main"; backend = (module Main) }]
      ~targets:[] ~archives:[]

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

let ck n = Printf.sprintf "%03x%013x-%016x" n n n

(* The last figures each callback was handed, which is what a reader is left
   looking at once the run is over. *)
type seen = {
  mutable marks : int;
  mutable closes : int;
  mutable roots : int;
  mutable promoted : int;
  mutable reclaimed : int;
}

let fresh () = { marks = 0; closes = 0; roots = 0; promoted = 0; reclaimed = 0 }

let put_chunk n =
  Main.put
    ~key:(chunk_prefix ^ Chunk_layout.relative_path (ck n))
    ~data:(Chunk.of_string "a chunk!")
    ()

let put_manifest n =
  let m =
    Manifest.make ~name:"f" ~h1:(String.make 16 '0') ~h2:(String.make 16 '0')
      ~size:8L ~chunk_size:8
      ~chunks:[Manifest.entry_of_key ~index:0 ~size:8 (ck n)]
      ~mtime:0.
  in
  Main.put
    ~key:(Printf.sprintf "%sfolder%02d/deadbeefdeadbeef" domain_prefix n)
    ~data:(Chunk.of_string (Manifest.to_string ~name:"f" m))
    ()

(* [live] chunks a manifest names and [garbage] that nothing does, so the run
   has something to reclaim and something to keep. *)
let build ~live ~garbage =
  ignore (Sys.command (Printf.sprintf "rm -rf %s && mkdir -p %s" root main_dir));
  let* () =
    Lwt_list.iter_s put_chunk (List.init (live + garbage) (fun i -> i))
  in
  Lwt_list.iter_s put_manifest (List.init live (fun i -> i))

let () =
  Lwt_main.run
    (let* () = build ~live:3 ~garbage:4 in
     let seen = fresh () in
     case "a collection that finishes inside one throttle interval";
     let* stats =
       G.run
         ~on_mark:(fun ~namespaces:_ ~total:_ ~roots ~promoted ->
           seen.marks <- seen.marks + 1;
           seen.roots <- roots;
           seen.promoted <- promoted)
         ~on_close:(fun ~shards:_ ~reclaimed ->
           seen.closes <- seen.closes + 1;
           seen.reclaimed <- reclaimed)
         ()
     in
     step "on_mark fired %d time(s), on_close %d" seen.marks seen.closes;
     step "callbacks ended on %d root(s), %d kept, %d reclaimed" seen.roots
       seen.promoted seen.reclaimed;
     step "stats say %d root(s), %d kept, %d reclaimed" stats.Gc.roots_marked
       stats.Gc.chunks_promoted stats.Gc.chunks_reclaimed;

     (* The phase is the thing a caller shows as "what it is doing now", so a
        phase that never reported is a phase a reader never saw happen. *)
     check "marking reported at all" (seen.marks > 0);
     check "closing reported at all" (seen.closes > 0);

     check "the run reclaimed something to disagree about"
       (stats.Gc.chunks_reclaimed > 0);
     check "roots agree"
       ~why:(fun () ->
         Printf.sprintf "callback %d, stats %d" seen.roots stats.Gc.roots_marked)
       (seen.roots = stats.Gc.roots_marked);
     check "chunks kept agree"
       ~why:(fun () ->
         Printf.sprintf "callback %d, stats %d" seen.promoted
           stats.Gc.chunks_promoted)
       (seen.promoted = stats.Gc.chunks_promoted);
     check "chunks reclaimed agree"
       ~why:(fun () ->
         Printf.sprintf "callback %d, stats %d" seen.reclaimed
           stats.Gc.chunks_reclaimed)
       (seen.reclaimed = stats.Gc.chunks_reclaimed);

     case "abandoning, which ends on a phase of its own";
     let* () = build ~live:3 ~garbage:4 in
     let seen = fresh () in
     let* s = G.start () in
     let* () = G.release s in
     let* stats =
       G.abort
         ~on_mark:(fun ~namespaces:_ ~total:_ ~roots:_ ~promoted ->
           seen.marks <- seen.marks + 1;
           seen.promoted <- promoted)
         ~on_close:(fun ~shards:_ ~reclaimed:_ ->
           seen.closes <- seen.closes + 1)
         ()
     in
     step "on_mark fired %d time(s); %d chunk(s) moved back" seen.marks
       seen.promoted;
     check "abandoning reported at all" (seen.marks > 0);
     check "chunks moved back agree"
       ~why:(fun () ->
         Printf.sprintf "callback %d, stats %d" seen.promoted
           stats.Gc.chunks_promoted)
       (seen.promoted = stats.Gc.chunks_promoted);

     report ~expected:8 ();
     Lwt.return_unit)
