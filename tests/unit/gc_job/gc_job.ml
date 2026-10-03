(* Known answers for the key a delete request is filed under (gc.md). OCaml
   composes it when a collection hands its deletes over; the bucket function
   parses it back to learn which domain asks, and refuses anything outside that
   domain's chunks. The rows are read back by [lambda/test_gc_job_key.py]
   (10 §3.1 item 4): a disagreement leaves every request ignored. *)

open Tsync_core

(* "gc-jobs" itself is a reserved domain name (01 §2.1). *)
let domains = ["dom"; "Jellyfin Media"; "chunks"; "gc-job"]

(* Fixed, so the file is the same on every run; two, because the run in the
   key keeps collections half a second apart from sharing a name. *)
let runs = [1755300000.; 1755300000.5]

let () =
  List.iter
    (fun name ->
      let d = Domain_name.v name in
      Printf.printf "prefix|%s|%s\n" name (Key.prefix_to_string (Key.gc_jobs d));
      List.iter
        (fun started ->
          let run = Key.run_name started in
          List.iter
            (fun shard ->
              Printf.printf "job|%s|%s|%s|%s\n" name run shard
                (Key.to_string (Key.discard_job d ~run ~shard)))
            ["000"; "abb"; "fff"])
        runs)
    domains;
  (* What the Python must refuse, so a chunk never reaches the delete path. *)
  List.iter
    (fun key -> Printf.printf "not-a-job|%s\n" key)
    [
      "tsync/dom/chunks/abb/cba685e06d3e500f-293331628d03f29b";
      "tsync/verify-jobs/dom/abb";
      "tsync/corrupted/dom/abb/cba685e06d3e500f-293331628d03f29b";
      "tsync/gc-jobs/dom/abb";
      "tsync/gc-jobs/dom/1755300000000/zz";
      "tsync/gc-jobs/dom/1755300000000/";
      "tsync/gc-jobs//1755300000000/abb";
    ];
  assert (Key.run_name (List.nth runs 0) <> Key.run_name (List.nth runs 1));
  List.iter
    (fun name ->
      let d = Domain_name.v name in
      let key = Key.discard_job d ~run:"1755300000000" ~shard:"abb" in
      assert (Key.chunk_of_marker key = None);
      assert (Key.parse_discard_job key = Some (d, "1755300000000", "abb")))
    domains;
  print_endline "ok"
