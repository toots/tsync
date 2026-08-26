(* What a collection does to the copies, which the scenario tests cannot say,
   having one store.

   Closing deletes off every replica and backfill target the same keys it
   discards on the main — no walk of the copies, so the cost is the garbage's and
   not the layout's. What that buys is also what it gives up, and both are
   pinned here: a chunk the main never had stays where it is, and a copy short of
   a chunk the main kept is not filled. Neither is drift this knows how to see;
   [tsync mirror] is what does.

   Chunk keys are built so each lands in a shard of its own, which is what makes
   "a shard the main never had" a case at all. *)

open Lwt.Syntax
open Check

let root = "/tmp/tsync-gc-targets-test"
let main_dir = root ^ "/main"
let replica_dir = root ^ "/replica"
let backfill_dir = root ^ "/backfill"
let chunk_prefix = "tsync/testdom/chunks/"
let domain_prefix = "tsync/testdom/manifests/"

module Main =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some main_dir)
         ()
      : Backend_lwt.Store)

module Replica =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some replica_dir)
         ()
      : Backend_lwt.Store)

module Backfill =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some backfill_dir)
         ()
      : Backend_lwt.Store)

module C : Conf_lwt.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = domain_prefix
  let chunk_prefix = chunk_prefix
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = Stored_key.in_space ~prefix:"tsync/testdom/" "cursor"
  let shares_prefix = "tsync/shares/"

  (* Reads and writes go to the main alone: this test is about what {!Gc} does to
     the copies, not about fan-out, and a composite would put every chunk on every
     store before the collection even started. *)
  let store = (module Main : Backend_lwt.Store)

  let members =
    [
      Backend.member ~role:`Main ~backend_type:"local" ~local_path:main_dir
        ~name:"main"
        (module Main : Backend_lwt.Store);
      Backend.member ~role:`Replica ~backend_type:"local"
        ~local_path:replica_dir ~name:"replica"
        (module Replica : Backend_lwt.Store);
      Backend.member ~role:`Backfill ~backend_type:"local"
        ~local_path:backfill_dir ~name:"backfill"
        (module Backfill : Backend_lwt.Store);
    ]

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

  include Conf_lwt.Monad
end

module G = Gc.Make (C)

(* "<h1>-<h2>", 16 hex each. Built so that [n] is the leading three characters,
   which is the shard ({!Chunk_layout.relative_path}). Numbering the low bits
   instead would put every chunk in shard 000 and the shard cases would not be
   cases. *)
let ck n = Printf.sprintf "%03x%013x-%016x" n n n

let key n =
  Stored_key.in_space ~prefix:chunk_prefix (Chunk_layout.relative_path (ck n))

let label n = Printf.sprintf "%03x" n

(* By what a chunk is named, the same question {!Gc} asks of a listing before it
   names anything in a delete. Filtering out directory markers instead let
   anything else through, so the two sides of this test answered "is that a
   chunk" differently from each other and from the code under test. *)
let chunks_of (module B : Backend_lwt.Store) =
  let+ entries = B.list_prefix ~prefix:chunk_prefix () in
  List.filter_map
    (fun (e : Backend.file_entry) ->
      let name = Filename.basename (Stored_key.to_string e.Backend.key) in
      if Chunks.is_chunk_key name then Some name else None)
    entries
  |> List.sort String.compare

(* Shown by shard, which is the leading three characters and, here, the chunk's
   number. *)
let show name store =
  let+ chunks = chunks_of store in
  step "%-9s %s" (name ^ ":")
    (if chunks = [] then "(none)"
     else String.concat " " (List.map (fun c -> String.sub c 0 3) chunks))

let () =
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s && mkdir -p %s %s %s" root main_dir
          replica_dir backfill_dir));
  Lwt_main.run
    ((* Chunks 1 and 3 are live: one manifest names both. Chunk 2 is on the main
        and unreferenced, so the collection reclaims it. *)
     let* () =
       Main.put ~key:(key 1) ~data:(Bigstring.of_string "live-one") ()
     in
     let* () =
       Main.put ~key:(key 2) ~data:(Bigstring.of_string "orphaned") ()
     in
     let* () =
       Main.put ~key:(key 3) ~data:(Bigstring.of_string "live-two") ()
     in
     let manifest =
       let entry index k = Manifest_fixture.entry_of_key ~index ~size:8 k in
       (* A manifest's own digest is 16 hex like a chunk's; its value is not
          examined here, only that the manifest parses and names its chunks. *)
       Manifest_fixture.make ~name:"f" ~h1:(String.make 16 '0')
         ~h2:(String.make 16 '0') ~size:16L ~chunk_size:8
         ~chunks:[entry 0 (ck 1); entry 1 (ck 3)]
         ~mtime:0.
     in
     let* () =
       Main.put
         ~key:(Stored_key.in_space ~prefix:domain_prefix "f")
         ~data:(Bigstring.of_string (Manifest.to_string ~name:"f" manifest))
         ()
     in
     (* The replica holds chunk 2, which the collection is about to reclaim, and
        chunk 9, which the main has never had; it is short chunk 3, which the
        collection keeps. One of each case the closing phase can meet. *)
     let* () =
       Replica.put ~key:(key 1) ~data:(Bigstring.of_string "live-one") ()
     in
     let* () =
       Replica.put ~key:(key 2) ~data:(Bigstring.of_string "orphaned") ()
     in
     let* () =
       Replica.put ~key:(key 9) ~data:(Bigstring.of_string "never-was") ()
     in
     (* The backfill target holds only the chunk the main never had, so it also
        pins that a delete naming keys this store does not have is not an error:
        every copy is sent the same list. *)
     let* () =
       Backfill.put ~key:(key 9) ~data:(Bigstring.of_string "never-was") ()
     in

     case "before";
     let* () = show "main" (module Main) in
     let* () = show "replica" (module Replica) in
     let* () = show "backfill" (module Backfill) in

     case "collect";
     let* s = G.run () in
     step "main reclaimed %d chunk(s), kept %d" s.Gc.chunks_reclaimed
       s.chunks_promoted;

     case "after";
     let* () = show "main" (module Main) in
     let* () = show "replica" (module Replica) in
     let* () = show "backfill" (module Backfill) in

     case "what that means";
     let* main = chunks_of (module Main) in
     let* replica = chunks_of (module Replica) in
     let* backfill = chunks_of (module Backfill) in
     step "the reclaimed chunk in shard %s is gone from the replica too: %b"
       (label 2)
       (not (List.mem (ck 2) replica));
     step "a live chunk the replica had is untouched: %b"
       (List.mem (ck 1) replica);
     (* The two the closing phase deliberately cannot see. Printed rather than
        asserted away, so the trade is in the snapshot instead of in a comment. *)
     step "the chunk in shard %s, which the main never had, is still there: %b"
       (label 9)
       (List.mem (ck 9) replica && List.mem (ck 9) backfill);
     step "the replica is still short chunk %s, which the main kept: %b"
       (label 3)
       (List.mem (ck 3) main && not (List.mem (ck 3) replica));
     step "filling either of those is tsync mirror's job, not this one's";

     (* The one case being absent from the space on its way out does not settle:
        a chunk is orphaned when the run opens, and a writer that never heard of
        the run uploads it again before closing reaches its shard. On the main
        the new name survives the discard, but a copy is sent keys rather than
        asked what it holds, so naming this one would take out a chunk something
        references again. *)
     case "a chunk uploaded again mid-run is not deleted off the copies";
     let* () =
       Main.put ~key:(key 4) ~data:(Bigstring.of_string "orphan-4") ()
     in
     let* () =
       Replica.put ~key:(key 4) ~data:(Bigstring.of_string "orphan-4") ()
     in
     let* s = G.start () in
     let rec until phase =
       if G.phase s = phase then Lwt.return_unit
       else
         let* outcome = G.step ~units:1 s in
         match outcome with `Done -> Lwt.return_unit | `More -> until phase
     in
     let* () = until "closing" in
     (* Marking is done and nothing referenced chunk 4, so it is sitting in the
        space on its way out. This is the writer, landing it in the space every
        write goes to. *)
     let* () =
       Main.put ~key:(key 4) ~data:(Bigstring.of_string "orphan-4") ()
     in
     let rec drain () =
       let* outcome = G.step ~units:16 s in
       match outcome with `Done -> Lwt.return_unit | `More -> drain ()
     in
     let* () = drain () in
     let* () = G.release s in
     let* main = chunks_of (module Main) in
     let* replica = chunks_of (module Replica) in
     step "the re-uploaded chunk %s survives on the main: %b" (label 4)
       (List.mem (ck 4) main);
     step "and is still on the replica, not deleted out from under it: %b"
       (List.mem (ck 4) replica);
     Lwt.return_unit)
