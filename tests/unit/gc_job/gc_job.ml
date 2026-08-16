(* Known-answer test for the key a delete request is filed under.

   OCaml composes it when a collection hands its deletes over; the function in
   the bucket parses it back to learn which domain is asking, and refuses to
   delete anything outside that domain's chunks. So a disagreement is not a
   cosmetic one: parsing that fails leaves every request ignored and the copy
   never emptied, and parsing that reads the wrong domain is the check on what a
   request may name reading the wrong answer.

   The rows are read back by [lambda/test_gc_job_key.py], which parses them with
   the Python implementation. One golden file, checked from both sides, with no
   third copy to drift.

   Domains cover what a real one looks like: a plain name, one with a space, and
   one spelled like the segments around it. *)

let chunk_prefix domain = "tsync/" ^ domain ^ "/chunks/"
let domains = ["dom"; "Jellyfin Media"; "chunks"; "gc-jobs"]

(* Fixed rather than taken from a clock, so the file is the same on every run.
   Two of them, because a name colliding across collections is what putting the
   run in the key exists to stop. *)
let runs = [1755300000.; 1755300000.5]

let () =
  List.iter
    (fun domain ->
      let cp = chunk_prefix domain in
      Printf.printf "prefix|%s|%s\n" domain (Chunk_layout.gc_jobs_prefix ~chunk_prefix:cp);
      List.iter
        (fun started ->
          let run = Chunk_layout.gc_run_name started in
          List.iter
            (fun shard ->
              Printf.printf "job|%s|%s|%s|%s\n" domain run shard
                (Chunk_layout.gc_job_key ~chunk_prefix:cp ~run shard))
            ["000"; "abb"; "fff"])
        runs)
    domains;
  (* Spelled like a request but for the pieces that make one: what the Python
     must refuse, so that a chunk is never handed to the delete path. *)
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
  (* Two collections a half second apart must not share a name: a bare shard
     would let the later one overwrite a request the earlier left unconsumed,
     losing its keys and the evidence that it stuck. *)
  assert (
    Chunk_layout.gc_run_name (List.nth runs 0)
    <> Chunk_layout.gc_run_name (List.nth runs 1));
  (* A request is never mistaken for a chunk on this side either. *)
  List.iter
    (fun domain ->
      let key =
        Chunk_layout.gc_job_key
          ~chunk_prefix:(chunk_prefix domain)
          ~run:"1755300000000" "abb"
      in
      assert (Chunk_layout.marker_key key = None);
      assert (Chunk_layout.shard_of_job key = Some "abb"))
    domains;
  print_endline "ok"
