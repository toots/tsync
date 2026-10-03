(* What a copy is believed to hold (gc §5.6, §5.8): believed only under the
   generation it was confirmed in, and a shard known only until one of its
   chunks is forgotten. *)

open Tsync_core
open Tsync_store

let p fmt = Printf.printf (fmt ^^ "\n%!")

let () =
  let g = ref (Some 2) in
  let memo = Copy_memo.create ~generation:(fun () -> !g) () in
  let a = Chunk_key.of_body "a" and b = Chunk_key.of_body "b" in
  let listings = ref 0 in
  let learn v ck =
    Copy_memo.learn_shard v (Chunk_key.shard ck) (fun () ->
        incr listings;
        [ck])
  in
  let v = Copy_memo.look memo in
  Copy_memo.note v a;
  p "noted under G=2: held %b, another chunk %b" (Copy_memo.holds v a)
    (Copy_memo.holds v b);
  learn v b;
  learn v b;
  p "a shard learnt twice is listed %d time(s); its chunk held %b" !listings
    (Copy_memo.holds v b);
  Copy_memo.forget memo [b];
  learn v b;
  p "after forgetting its chunk it is listed again: %d" !listings;
  g := Some 3;
  let odd = Copy_memo.look memo in
  Copy_memo.note odd a;
  p "under an odd G: trusted %b, held %b" (Copy_memo.trusted odd)
    (Copy_memo.holds odd a);
  g := Some 4;
  let later = Copy_memo.look memo in
  p "under G=4: what G=2 confirmed is held %b" (Copy_memo.holds later a);
  Copy_memo.note later a;
  p "an old view after G moved on: held %b, and it records nothing: %b"
    (Copy_memo.holds v a)
    (Copy_memo.note v b;
     not (Copy_memo.holds later b));
  g := None;
  p "G unreadable: trusted %b" (Copy_memo.trusted (Copy_memo.look memo))
