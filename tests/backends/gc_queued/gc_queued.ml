(* Closing against a copy that takes the deletes rather than doing them.

   A store whose bucket runs the delete function answers {!Backend.S.discard}
   with [`Queued], having written the batch as a request its own notification
   would deliver. What that buys is that the collection stops waiting on other
   people's stores; what it gives up is that the copy is only clean once
   something consumes the request, and both are in the snapshot below.

   The consumer here applies the rules [lambda/verify.py] applies, so what is
   pinned is the contract between the two halves rather than either alone. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "gc-queued"
let main_dir = Filename.concat root "main"
let replica_dir = Filename.concat root "replica"
let chunk_prefix = "tsync/testdom/chunks/"

module L = Chunk_layout.Make (struct
  let chunk_prefix = chunk_prefix
end)

let domain_prefix = "tsync/testdom/manifests/"
let jobs_prefix = L.gc_jobs_prefix

module Main = (val Fixture.local_store ~verify_writes:false main_dir)
module Disk = (val Fixture.local_store ~verify_writes:false replica_dir)

(* A copy standing in for one whose bucket wakes a function: the request goes
   into the store itself, which is what makes it durable before this answers and
   what leaves it visible when nothing consumes it. *)
module Replica : Backend.S = struct
  include Disk

  let discard ~chunk_prefix ~run ~name ~keys () =
    let+ () =
      Disk.put ~key:(L.gc_job_key ~run name)
        ~data:(Bigstring.of_string (Discard_job.encode keys))
        ()
    in
    `Queued
end

module C =
  (val Fixture.conf ~domain:"testdom" ~root ~verify_writes:false
         ~store:(module Main)
         ~members:
           [
             Backend.member ~role:"main" ~backend_type:"local"
               ~local_path:main_dir ~name:"main"
               (module Main);
             Backend.member ~role:"replica" ~backend_type:"s3" ~name:"replica"
               (module Replica);
           ]
         ())

module G = Gc.Make (C)

let ck n = Printf.sprintf "%03x%013x-%016x" n n n
let key n = chunk_prefix ^ Chunk_layout.relative_path (ck n)

let chunks_of (module B : Backend.S) =
  let+ entries = B.list_prefix ~prefix:chunk_prefix () in
  List.filter_map
    (fun (e : Backend.file_entry) ->
      let name = Filename.basename e.Backend.key in
      if Chunks.is_chunk_key name then Some name else None)
    entries
  |> List.sort String.compare

(* The function the notification would wake, by the same rules: derive each
   chunk's marker rather than expect it in the body, and delete the request last
   so a run that died partway leaves it to be seen. *)
let consume_requests (module B : Backend.S) =
  let* entries = B.list_prefix ~prefix:jobs_prefix () in
  let+ consumed =
    Lwt_list.filter_map_s
      (fun (e : Backend.file_entry) ->
        let* body = B.get_opt ~key:e.Backend.key () in
        match body with
          | None -> Lwt.return_none
          | Some body ->
              let keys = Discard_job.decode (Bigstring.to_string body) in
              let* () =
                B.delete_multi
                  (keys @ List.filter_map Chunk_layout.marker_key keys)
              in
              let+ () = B.delete ~key:e.Backend.key () in
              Some (List.length keys))
      entries
  in
  List.fold_left ( + ) 0 consumed

let () =
  Lwt_main.run
    ((* Chunks 1 and 3 are live; 2 is unreferenced and is what the collection
        reclaims. The replica holds all three, plus a marker accusing 2 — which
        must go with it, nothing else ever being able to clear one. *)
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
       Manifest_fixture.make ~name:"f" ~h1:(String.make 16 '0')
         ~h2:(String.make 16 '0') ~size:16L ~chunk_size:8
         ~chunks:[entry 0 (ck 1); entry 1 (ck 3)]
         ~mtime:0.
     in
     let* () =
       Main.put ~key:(domain_prefix ^ "f")
         ~data:(Bigstring.of_string (Manifest.to_string ~name:"f" manifest))
         ()
     in
     let* () =
       Disk.put ~key:(key 1) ~data:(Bigstring.of_string "live-one") ()
     in
     let* () =
       Disk.put ~key:(key 2) ~data:(Bigstring.of_string "orphaned") ()
     in
     let marker = Option.get (Chunk_layout.marker_key (key 2)) in
     let* () = Disk.put ~key:marker ~data:(Bigstring.of_string "{}") () in

     case "the collection returns without the copy having been touched";
     let* s = G.run () in
     step "main reclaimed %d chunk(s), kept %d" s.Gc.chunks_reclaimed
       s.chunks_promoted;
     let* main = chunks_of (module Main) in
     let* replica = chunks_of (module Disk) in
     check "the main is done with it" (not (List.mem (ck 2) main));
     (* The trade, stated rather than commented: the copy is still holding the
        garbage, and will until something consumes the request. *)
     check "the copy still holds the reclaimed chunk" (List.mem (ck 2) replica);
     let* jobs = Disk.list_prefix ~prefix:jobs_prefix () in
     check "because the delete was handed over, not done" (jobs <> []);

     case "and says so, which is the only thing that would";
     let* stuck = G.outstanding () in
     step "copies with requests outstanding: %s"
       (String.concat ", "
          (List.map (fun (name, n, _) -> Printf.sprintf "%s (%d)" name n) stuck));
     check "the replica is named"
       (List.map (fun (name, _, _) -> name) stuck = ["replica"]);

     (* The notification a request fires is spent once, so a function that was
        not listening then does not pick it up by being fixed. Re-delivery is
        writing the request back where it already is. *)
     case "a request can be handed over again";
     let* again = G.retry_outstanding () in
     step "copies re-sent: %s"
       (String.concat ", "
          (List.map (fun (n, c) -> Printf.sprintf "%s (%d)" n c) again));
     check "the replica's request was sent again"
       (List.assoc_opt "replica" again = Some 1);
     let* stuck = G.outstanding () in
     check "and it is still outstanding until something consumes it"
       (List.map (fun (n, _, _) -> n) stuck = ["replica"]);
     let* body = Disk.get_opt ~key:(List.hd jobs).Backend.key () in
     check "with the keys it named intact"
       (Option.map (fun b -> Discard_job.decode (Bigstring.to_string b)) body
       = Some [key 2]);

     case "once the function runs";
     let* dropped = consume_requests (module Disk) in
     step "the request named %d chunk(s)" dropped;
     let* replica = chunks_of (module Disk) in
     check "the reclaimed chunk is gone from the copy too"
       (not (List.mem (ck 2) replica));
     check "the live chunk it held is untouched" (List.mem (ck 1) replica);
     (* Derived by the function from the chunk key, never listed in the request:
        a marker outliving its chunk accuses something no repair can answer. *)
     let* still = Disk.head_opt ~key:marker () in
     check "and the marker accusing it went with it" (still = None);
     let* stuck = G.outstanding () in
     check "nothing is outstanding any more" (stuck = []);

     case "a request is not mistaken for anything else";
     let job = (List.hd jobs).Backend.key in
     check "not for a chunk" (Chunk_layout.marker_key job = None);
     let* main = chunks_of (module Main) in
     check "and the main still has what it kept"
       (List.mem (ck 1) main && List.mem (ck 3) main);

     report ~expected:13 ();
     Lwt.return_unit)
