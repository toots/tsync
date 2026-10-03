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

(* 06 §5: a store with no batch read answers many keys a few at a time. *)
let () =
  Rt.run_sync (fun () ->
      let inner =
        Local.create ~name:"slow"
          (Filename.concat
             (Filename.get_temp_dir_name ())
             (Printf.sprintf "tsync-read-many-%d" (Unix.getpid ())))
      in
      let reading = Atomic.make 0 and most = Atomic.make 0 in
      let slow =
        {
          inner with
          get_many = None;
          get_opt =
            (fun k ->
              let now = Atomic.fetch_and_add reading 1 + 1 in
              if now > Atomic.get most then Atomic.set most now;
              Rt.sleep 0.05;
              Atomic.decr reading;
              inner.get_opt k);
        }
      in
      let entries =
        List.init 24 (fun i ->
            let key = Key.v (Printf.sprintf "tsync/d/many/%02d" i) in
            inner.put key (Bigstring.of_string (string_of_int i));
            Option.get (inner.head_opt key))
      in
      let got = Store.read_many slow entries in
      p
        "24 keys read singly: in order %b, more than one at a time %b, at most \
         8 %b"
        (List.mapi
           (fun i (_, b) ->
             Option.map Bigstring.to_string b = Some (string_of_int i))
           got
        |> List.for_all Fun.id)
        (Atomic.get most > 1)
        (Atomic.get most <= 8);
      inner.delete_multi (List.map (fun (e : Store.entry) -> e.key) entries))
