(* Bringing the copies into line once the main has been collected.

   A replica is meant to be a complete copy, so a gap in one is drift and gets
   filled. A backfill target is incomplete by design — it is filled behind the
   write and has its own queue for that — so a gap there says nothing and is left
   alone. Both lose whatever the main no longer has.

   Three things this pins down that the scenario tests cannot, having one store:
   the walk is driven by the target's own shards (so a chunk in a shard the main
   has never had is still found), a replica is filled, and a backfill target is
   not. *)

open Lwt.Syntax

let root = "/tmp/tsync-gc-reconcile-test"
let main_dir = root ^ "/main"
let replica_dir = root ^ "/replica"
let backfill_dir = root ^ "/backfill"
let chunk_prefix = "tsync/testdom/chunks/"
let domain_prefix = "tsync/testdom/manifests/"

module Main = (val Local_backend.make ~root:main_dir : Backend.S)
module Replica = (val Local_backend.make ~root:replica_dir : Backend.S)
module Backfill = (val Local_backend.make ~root:backfill_dir : Backend.S)

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

  (* Reads and writes go to the main alone: this test is about what {!Gc} does to
     the copies, not about fan-out, and a composite would put every chunk on every
     store before the collection even started. *)
  let store = (module Main : Backend.S)

  let members =
    [
      Backend.member ~role:"main" ~backend_type:"local" ~local_path:main_dir
        ~name:"main" (module Main);
      Backend.member ~role:"replica" ~backend_type:"local"
        ~local_path:replica_dir ~name:"replica" (module Replica);
      Backend.member ~role:"backfill" ~backend_type:"local"
        ~local_path:backfill_dir ~name:"backfill" (module Backfill);
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
end

module G = Gc.Make (C)

let step fmt = Printf.printf ("  " ^^ fmt ^^ "\n")
let case name = Printf.printf "\n=== %s\n" name

(* "<h1>-<h2>", 16 hex each. Built so that [n] is the leading three characters,
   which is the shard ({!Chunk_layout.relative_path}) — the point being that each
   of these chunks lands in a shard of its own. Without that, "a shard the main has
   never had" would not be tested at all: numbering the low bits instead puts every
   chunk in shard 000. *)
let ck n = Printf.sprintf "%03x%013x-%016x" n n n
let key n = chunk_prefix ^ Chunk_layout.relative_path (ck n)
let label n = Printf.sprintf "%03x" n

let chunks_of (module B : Backend.S) =
  let+ entries = B.list_prefix ~prefix:chunk_prefix () in
  List.filter_map
    (fun (e : Backend.file_entry) ->
      let k = e.Backend.key in
      if String.length k > 0 && k.[String.length k - 1] = '/' then None
      else Some (Filename.basename k))
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
     let* () = Main.put ~key:(key 1) ~data:"live-one" () in
     let* () = Main.put ~key:(key 2) ~data:"orphaned" () in
     let* () = Main.put ~key:(key 3) ~data:"live-two" () in
     let manifest =
       let entry index k = Manifest.entry_of_key ~index ~size:8 k in
       (* A manifest's own digest is 16 hex like a chunk's; its value is not
          examined here, only that the manifest parses and names its chunks. *)
       Manifest.make ~name:"f" ~h1:(String.make 16 '0') ~h2:(String.make 16 '0')
         ~size:16L ~chunk_size:8
         ~chunks:[entry 0 (ck 1); entry 1 (ck 3)]
         ~mtime:0.
     in
     let* () =
       Main.put ~key:(domain_prefix ^ "f")
         ~data:(Manifest.to_string ~name:"f" manifest)
         ()
     in
     (* The replica holds two chunks it should not — chunk 2, which the collection
        is about to reclaim, and chunk 9, which the main has never had at all — and
        is short one it should have, chunk 3. So both directions are exercised: what
        it has too much of goes, what it lacks is filled. *)
     let* () = Replica.put ~key:(key 1) ~data:"live-one" () in
     let* () = Replica.put ~key:(key 2) ~data:"orphaned" () in
     let* () = Replica.put ~key:(key 9) ~data:"never-was" () in
     (* The backfill target is behind — it has neither live chunk — and also holds
        one the main never had. It must lose that one and be filled with nothing:
        being behind is not drift for a target whose whole job is catching up. *)
     let* () = Backfill.put ~key:(key 9) ~data:"never-was" () in

     case "before";
     let* () = show "main" (module Main) in
     let* () = show "replica" (module Replica) in
     let* () = show "backfill" (module Backfill) in

     case "collect";
     let* s = G.run () in
     step "main reclaimed %d chunk(s), kept %d" s.Gc.chunks_reclaimed
       s.chunks_promoted;
     List.iter
       (fun (m : Gc.member_stats) ->
         step "%-9s %d deleted, %d filled" (m.Gc.name ^ ":") m.deleted
           m.uploaded)
       s.members;

     case "after";
     let* () = show "main" (module Main) in
     let* () = show "replica" (module Replica) in
     let* () = show "backfill" (module Backfill) in

     case "what that means";
     let* main = chunks_of (module Main) in
     let* replica = chunks_of (module Replica) in
     let* backfill = chunks_of (module Backfill) in
     step "replica now matches the main: %b" (replica = main);
     step "the chunk in shard %s, which the main never had, is gone from both: %b"
       (label 9)
       (not (List.mem (ck 9) replica || List.mem (ck 9) backfill));
     step "the backfill target was not filled, only trimmed: %b"
       (backfill = []);
     Lwt.return_unit)
