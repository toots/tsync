(* Which of the three sources answers "is this chunk already stored", and in
   what order.

   The order is the policy. A chunk this session placed is in the memo, and a
   corruption marker says exactly that what it placed is not what landed —
   asking the store would not help either, a corrupt chunk being the right size
   and so present. Answering "stored" there would leave the marker with nothing
   to clear it and, because dedup is what makes a chunk shared, hand the bad
   bytes to every later file containing it.

   So each case asserts what was consulted as well as what came back: an
   ordering that reaches the store when it should not is wrong even when the
   verdict happens to agree. *)

open Lwt.Syntax
open Check

let key = "aaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb"

(* Counting probes rather than stubbing them out, so "never asked" is a fact the
   test states rather than one it assumes. *)
let probes () =
  let asked = ref [] in
  let record name answer k =
    asked := (name, k) :: !asked;
    Lwt.return answer
  in
  (asked, record)

module Dedup = Dedup_lwt

let () =
  Lwt_main.run
    (case "a corrupt key is absent, and nothing else is consulted";
     let asked, record = probes () in
     let t = Dedup.create () in
     Dedup.remember t key;
     let* answer =
       Dedup.known t ~corrupt:(record "corrupt" true)
         ~present:(record "present" true) key
     in
     check "reported absent" (answer = false) ~why:(fun () ->
         "a marked key read as stored");
     check "the store was never asked"
       (not (List.mem_assoc "present" !asked))
       ~why:(fun () -> "consulted: " ^ String.concat "," (List.map fst !asked));

     case "a remembered key is present without a round trip";
     let asked, record = probes () in
     let t = Dedup.create () in
     Dedup.remember t key;
     let* answer =
       Dedup.known t ~corrupt:(record "corrupt" false)
         ~present:(record "present" false) key
     in
     check "reported stored" (answer = true);
     check "the store was never asked"
       (not (List.mem_assoc "present" !asked))
       ~why:(fun () -> "consulted: " ^ String.concat "," (List.map fst !asked));

     case "an unknown key falls through to the store";
     let asked, record = probes () in
     let t = Dedup.create () in
     let* answer =
       Dedup.known t ~corrupt:(record "corrupt" false)
         ~present:(record "present" true) key
     in
     check "the store's answer is taken" (answer = true);
     check "and it was asked" (List.mem_assoc "present" !asked);

     case "the memo is bounded, and holds something until it is";
     let t = Dedup.create ~max_known:(fun () -> 8) () in
     for i = 1 to 8 do
       Dedup.remember t (Printf.sprintf "%016x-%016x" i i)
     done;
     check "it filled" (Dedup.count t = 8);
     Dedup.remember t "cccccccccccccccc-dddddddddddddddd";
     check "and cleared rather than growing past the cap" (Dedup.count t = 1);

     report ~expected:8 ();
     Lwt.return_unit)
