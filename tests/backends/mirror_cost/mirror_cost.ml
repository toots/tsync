(* What a resync *costs*, counted, rather than what it leaves behind.

   The scenario tests check the end state of a store holding a handful of
   objects, and a store that small cannot show the difference between asking
   once and asking per object. Every defect this file exists for was invisible
   to them:

   - A HEAD per object per destination, at a concurrency meant for whole bodies.
     On a domain of any size that is the entire runtime, spent before a byte is
     copied, and it grows with the domain rather than with what is missing.
   - An object missing on two destinations fetched from the source twice,
     destinations being walked one after another over the same listing.
   - A destination copied to because another one was behind.

   All three are about counts, not outcomes, so counts are what this checks. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "mirror-cost"
let main_dir = Scratch.sub root "main"
let a_dir = Scratch.sub root "replica_a"
let b_dir = Scratch.sub root "replica_b"
let chunk_prefix = "tsync/testdom/chunks/"
let domain_prefix = "tsync/testdom/manifests/"

type tally = {
  mutable lists : int;
  mutable folds : int;
  mutable pages : int;
  mutable heads : int;
  mutable gets : int;
  mutable puts : int;
}

let counted () =
  { lists = 0; folds = 0; pages = 0; heads = 0; gets = 0; puts = 0 }

let main_ops = counted ()
let a_ops = counted ()
let b_ops = counted ()

let reset () =
  List.iter
    (fun t ->
      t.lists <- 0;
      t.folds <- 0;
      t.pages <- 0;
      t.heads <- 0;
      t.gets <- 0;
      t.puts <- 0)
    [main_ops; a_ops; b_ops]

(* Passes everything through and keeps score. [lists] and [folds] are counted
   apart so that a listing quietly reverting to the whole-namespace call shows
   up as a moved number rather than as nothing. *)
module Count
    (B : Backend.S)
    (T : sig
      val t : tally
    end) : Backend.S = struct
  include B

  let list_prefix ?max_keys ~prefix () =
    T.t.lists <- T.t.lists + 1;
    B.list_prefix ?max_keys ~prefix ()

  let fold_prefix ?max_keys ~prefix ~f () =
    T.t.folds <- T.t.folds + 1;
    B.fold_prefix ?max_keys ~prefix
      ~f:(fun page ->
        T.t.pages <- T.t.pages + 1;
        f page)
      ()

  let head_opt ~key () =
    T.t.heads <- T.t.heads + 1;
    B.head_opt ~key ()

  let get ~key () =
    T.t.gets <- T.t.gets + 1;
    B.get ~key ()

  let put ~key ~data () =
    T.t.puts <- T.t.puts + 1;
    B.put ~key ~data ()
end

(* Bodies here stand in for chunks without hashing to the names they are filed
   under, and a store that checks would spend the run filing corruption markers
   for every one of them. What is being counted is round trips. *)
let local dir =
  Backend.make ~backend_type:"local" ~get_field:(function
    | "verifyWrites" -> Some "false"
    | _ -> Some dir)

module Main =
  Count
    ((val local main_dir : Backend.S))
    (struct
      let t = main_ops
    end)

module Replica_a =
  Count
    ((val local a_dir : Backend.S))
    (struct
      let t = a_ops
    end)

module Replica_b =
  Count
    ((val local b_dir : Backend.S))
    (struct
      let t = b_ops
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
      Backend.member ~role:"replica" ~backend_type:"local" ~local_path:a_dir
        ~name:"replica_a"
        (module Replica_a);
      Backend.member ~role:"replica" ~backend_type:"local" ~local_path:b_dir
        ~name:"replica_b"
        (module Replica_b);
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

module M = Mirror.Make (C)

let ck n = Printf.sprintf "%03x%013x-%016x" n n n

(* Enough that "once per object" and "once per namespace" cannot be confused for
   each other, and enough pages that a page count means something. *)
let objects = 64

(* Every progress call the run made, so the phases can be counted rather than
   watched. *)
let progress : Mirror.progress list ref = ref []

let resync ?scope () =
  progress := [];
  let+ dests =
    M.resync ~source:"main" ?scope
      ~on_progress:(fun p -> progress := p :: !progress)
      ()
  in
  List.map
    (fun (d : Mirror.dest_stats) ->
      (d.Mirror.name, d.Mirror.checked, d.Mirror.copied))
    dests

let () =
  Lwt_main.run
    (let* () =
       Lwt_list.iter_s
         (fun n ->
           let* () =
             Main.put
               ~key:(chunk_prefix ^ Chunk_layout.relative_path (ck n))
               ~data:(Chunk.of_string "a chunk!")
               ()
           in
           Main.put
             ~key:(Printf.sprintf "%sfile%03d.bin" domain_prefix n)
             ~data:(Chunk.of_string "a manifest body")
             ())
         (List.init objects Fun.id)
     in
     (* The cursor sits under no listed prefix, so it is the one key still asked
        after by name — and the only reason the HEAD counts below are not
        expected to be flat zero. *)
     let* () = Main.put ~key:C.cursor_key ~data:(Chunk.of_string "cursor") () in

     case "filling two empty replicas";
     reset ();
     let* stats = resync () in
     step "objects on the main: %d chunks + %d manifests" objects objects;
     List.iter
       (fun (name, checked, copied) ->
         step "%s: %d checked, %d copied" name checked copied)
       stats;
     step "HEADs asked of replica_a: %d  <- one per object would be %d"
       a_ops.heads (objects * 2);
     step "HEADs asked of replica_b: %d  <- the cursor, and nothing else"
       b_ops.heads;
     step
       "listings of the main: %d fold(s) over %d page(s), %d whole-namespace \
        call(s)"
       main_ops.folds main_ops.pages main_ops.lists;
     step "listings of replica_a: %d fold(s), %d whole-namespace call(s)"
       a_ops.folds a_ops.lists;
     step "bodies fetched from the main: %d  <- both replicas want all %d"
       main_ops.gets (objects * 2);
     step "objects written to replica_a: %d, to replica_b: %d" a_ops.puts
       b_ops.puts;

     case "a second run, with nothing to do";
     reset ();
     let* stats = resync () in
     List.iter
       (fun (name, checked, copied) ->
         step "%s: %d checked, %d copied" name checked copied)
       stats;
     step "bodies fetched from the main: %d" main_ops.gets;
     step "objects written to the replicas: %d and %d" a_ops.puts b_ops.puts;
     step
       "HEADs asked of the replicas: %d and %d  <- the diff decides, not the \
        copies"
       a_ops.heads b_ops.heads;

     case "one chunk missing on replica_a alone";
     let gone = chunk_prefix ^ Chunk_layout.relative_path (ck 7) in
     let* () = Replica_a.delete ~key:gone () in
     reset ();
     let* stats = resync () in
     List.iter (fun (name, _, copied) -> step "%s: %d copied" name copied) stats;
     step "bodies fetched from the main: %d" main_ops.gets;
     step "written to replica_a: %d, to replica_b: %d  <- b was not behind"
       a_ops.puts b_ops.puts;

     case "an object of the wrong size on replica_b alone";
     let short = Printf.sprintf "%sfile%03d.bin" domain_prefix 9 in
     let* () = Replica_b.put ~key:short ~data:(Chunk.of_string "short") () in
     reset ();
     let* stats = resync () in
     List.iter (fun (name, _, copied) -> step "%s: %d copied" name copied) stats;
     step "bodies fetched from the main: %d" main_ops.gets;
     step "written to replica_a: %d, to replica_b: %d" a_ops.puts b_ops.puts;

     (* Structural rather than a matter of how many keys the folder holds: the
        scoped path never reaches a namespace listing at all, so unifying it
        onto the merge join to save a branch would move these off zero. *)
     (* A phase that reports nothing is a phase nobody can see running, and the
        listing phase is the one that answers nothing until it is done. *)
     case "every phase says it is running";
     reset ();
     let* () =
       Replica_a.delete
         ~key:(chunk_prefix ^ Chunk_layout.relative_path (ck 11))
         ()
     in
     let* (_ : (string * int * int) list) = resync () in
     let phases_seen =
       List.sort_uniq compare
         (List.map
            (fun (p : Mirror.progress) -> Mirror.string_of_phase p.Mirror.phase)
            !progress)
     in
     step "phases that reported: %s" (String.concat ", " phases_seen);
     step "reports in total: %d" (List.length !progress);
     let totals_known =
       List.filter
         (fun (p : Mirror.progress) -> p.Mirror.total <> None)
         !progress
     in
     step "reports carrying a total: %d  <- listing has none to carry"
       (List.length totals_known);

     case "a scoped resync is not a namespace sweep";
     reset ();
     let* stats = resync ~scope:(`Path "nothing-here") () in
     List.iter
       (fun (name, checked, copied) ->
         step "%s: %d checked, %d copied" name checked copied)
       stats;
     step "listings of the main during --path: %d fold(s), %d call(s)"
       main_ops.folds main_ops.lists;
     step
       "listings of the replicas during --path: %d and %d  <- a folder is not \
        a namespace"
       (a_ops.folds + a_ops.lists)
       (b_ops.folds + b_ops.lists);

     Printf.printf "\n";
     Lwt.return_unit)
