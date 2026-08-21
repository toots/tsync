(* A hash table that keeps its entries in a mapping, against the one it stands
   in for.

   The subset is only worth having if it behaves as Hashtbl does, so most of
   what follows compares the two directly over the same bindings. What it must
   add on top is that the entries are not words the collector walks, which is
   the last case and the reason the module exists. *)

open Check
module H = Hashtbl_mmap.Make (Hashtbl_mmap.String) (Hashtbl_mmap.Int)

let live () = (Stdlib.Gc.stat ()).Stdlib.Gc.live_words

(* Long enough that a key is a heap block rather than a word, which is what the
   keys this stands in for look like. *)
let key i =
  Printf.sprintf "tsync/domain/chunks/%03x/%016x-%016x" (i land 0xfff) i (i * 7)

let bulk = 20_000

let () =
  case "a binding goes in and comes back";
  let t = H.create 16 in
  H.replace t "a" 1;
  H.replace t "b" 2;
  check "find_opt answers with what was bound" (H.find_opt t "a" = Some 1);
  check "find answers the same" (H.find t "b" = 2);
  check "mem agrees" (H.mem t "a" && H.mem t "b");
  check "an absent key is absent" (H.find_opt t "c" = None);
  check "and find raises for it"
    (match H.find t "c" with _ -> false | exception Not_found -> true);
  check "length counts the bindings" (H.length t = 2);

  case "replace overwrites rather than shadows";
  H.replace t "a" 99;
  check "the new value wins" (H.find t "a" = 99);
  check "and the table did not grow" (H.length t = 2);

  case "a key is an arbitrary byte string";
  let odd =
    ["with\nnewline"; "with\ttab"; "with\000nul"; ""; String.make 300 'x']
  in
  List.iteri (fun i k -> H.replace t k i) odd;
  check "every one of them reads back"
    ~why:(fun () ->
      String.concat ", "
        (List.mapi
           (fun i k -> Printf.sprintf "%d:%b" i (H.find_opt t k = Some i))
           odd))
    (List.for_all2
       (fun k i -> H.find_opt t k = Some i)
       odd
       (List.init (List.length odd) Fun.id));
  check "and they did not collide with each other"
    (H.length t = 2 + List.length odd);

  (* The hint is a hint: everything must survive the growth it triggers, on both
     the record side and the slot side. *)
  case "the table grows past the hint it was created with";
  let t = H.create 8 in
  for i = 0 to bulk - 1 do
    H.replace t (key i) i
  done;
  check "length is what went in" (H.length t = bulk);
  let all_found = ref true and wrong = ref (-1) in
  for i = 0 to bulk - 1 do
    if H.find_opt t (key i) <> Some i then (
      all_found := false;
      if !wrong < 0 then wrong := i)
  done;
  check "every binding survived"
    ~why:(fun () -> Printf.sprintf "first wrong at %d" !wrong)
    !all_found;
  check "and nothing that was never bound appears"
    (H.find_opt t (key bulk) = None && H.find_opt t "" = None);

  case "iter and fold see each binding once";
  let seen = Hashtbl.create bulk in
  H.iter (fun k v -> Hashtbl.replace seen k v) t;
  check "iter visits every key" (Hashtbl.length seen = bulk);
  check "with the right value"
    (Hashtbl.find_opt seen (key 7) = Some 7
    && Hashtbl.find_opt seen (key (bulk - 1)) = Some (bulk - 1));
  check "fold counts the same" (H.fold (fun _ _ n -> n + 1) t 0 = bulk);
  check "and sums what iter saw"
    (H.fold (fun _ v n -> n + v) t 0 = Hashtbl.fold (fun _ v n -> n + v) seen 0);

  (* Held as OCaml values these bindings are a string, a boxed key and a bucket
     apiece; here they are pages.

     Keys no earlier case has bound, or anything that quietly kept them would
     already be holding these and would read as holding nothing. *)
  case "the bindings are not words the collector walks";
  let fresh i = key (i + bulk) in
  let before = live () in
  let mapped = H.create 8 in
  for i = 0 to bulk - 1 do
    H.replace mapped (fresh i) i
  done;
  let mapped_words = live () - before in
  let before = live () in
  let heaped = Hashtbl.create 8 in
  for i = 0 to bulk - 1 do
    Hashtbl.replace heaped (fresh i) i
  done;
  let heaped_words = live () - before in
  check "a mapped table costs a fraction of the heap one"
    ~why:(fun () ->
      Printf.sprintf "%d mapped vs %d heaped" mapped_words heaped_words)
    (mapped_words * 8 < heaped_words);
  check "the heap one really did hold them" (Hashtbl.length heaped = bulk);
  report ~expected:19 ()
