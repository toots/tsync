(* The spool a resync diffs two listings through.

   Everything here is a property the merge join depends on and would misread
   rather than fail on: an order it does not enforce, a duplicate it counts
   twice, a comparison that disagrees with the one the stores sort by, or a
   mapping that stops serving bytes once the file behind it is gone. *)

open Lwt.Syntax
open Check

let dir = "/tmp/tsync-listing-spool-test"
let entry key size = Backend.{ key; size; last_modified = 0. }
let page ks = List.map (fun (k, n) -> entry k n) ks

let spool_of ~label pages =
  let* t = Listing_spool.create ~dir ~label in
  let* () = Lwt_list.iter_s (Listing_spool.add t) pages in
  Listing_spool.seal t

(* Everything the cursor yields, so a walk can be compared against what went
   in. *)
let drain s =
  let c = Listing_spool.cursor s in
  let acc = ref [] in
  while not (Listing_spool.at_end c) do
    acc := (Listing_spool.key c, Listing_spool.size c) :: !acc;
    Listing_spool.advance c
  done;
  List.rev !acc

let key_of i = Printf.sprintf "tsync/dom/chunks/%06d" i

let () =
  Lwt_main.run
    (let* () = Fs_util.mkdir_p dir in
     let* () = Listing_spool.sweep ~dir in

     print_endline "=== three pages in, one walk out";
     let written =
       List.init 3 (fun p -> List.init 1000 (fun i -> ((p * 1000) + i, i)))
     in
     let pages =
       List.map
         (fun p -> page (List.map (fun (i, n) -> (key_of i, n)) p))
         written
     in
     let* s = spool_of ~label:"chunks on main" pages in
     let walked = drain s in
     Printf.printf "  count %d, first %s, last %s\n" (Listing_spool.count s)
       (fst (List.hd walked))
       (fst (List.nth walked (List.length walked - 1)));
     check "every record comes back" (Listing_spool.count s = 3000);
     check "the walk agrees with the count"
       (List.length walked = Listing_spool.count s);
     check "keys and sizes come back as written"
       (walked
       = List.concat_map (List.map (fun (i, n) -> (key_of i, n))) written);

     print_endline "\n=== a key repeated across a page boundary";
     let* dup =
       spool_of ~label:"dup"
         [page [("a", 1); ("b", 2)]; page [("b", 2); ("c", 3)]]
     in
     Printf.printf "  %s\n" (String.concat " " (List.map fst (drain dup)));
     check "the repeat is dropped rather than counted twice"
       (Listing_spool.count dup = 3);

     print_endline "\n=== a key below its predecessor";
     let* out_of_order =
       Lwt.catch
         (fun () ->
           let+ (_ : Listing_spool.sealed) =
             spool_of ~label:"chunks on replica"
               [page [("a", 1); ("c", 1)]; page [("b", 1)]]
           in
           "no exception raised")
         (function
           | Listing_spool.Out_of_order { spool; previous; next } ->
               Lwt.return
                 (Printf.sprintf "Out_of_order spool=%s previous=%s next=%s"
                    spool previous next)
           | exn -> Lwt.return (Printexc.to_string exn))
     in
     Printf.printf "  %s\n" out_of_order;
     check "a descending key raises rather than producing a wrong diff"
       (out_of_order = "Out_of_order spool=chunks on replica previous=c next=b");

     print_endline "\n=== an empty listing";
     let* empty = spool_of ~label:"empty" [] in
     let c = Listing_spool.cursor empty in
     check "holds nothing" (Listing_spool.count empty = 0);
     check "and is at its end immediately" (Listing_spool.at_end c);

     print_endline "\n=== comparison agrees with the order stores list in";
     (* '-' is 0x2D, '/' 0x2F, '0' 0x30, and \xff is above every letter: the
        pairs a signed-byte or name-wise comparison gets wrong. *)
     let adversarial =
       ["a"; "a-"; "a/z"; "a0"; "aa"; "b/"; "b0"; "z\xff"; "z\xff\xff"]
     in
     let* cmp =
       spool_of ~label:"cmp" [page (List.map (fun k -> (k, 0)) adversarial)]
     in
     check "the spool took them as already ascending"
       (Listing_spool.count cmp = List.length adversarial);
     let ok = ref true in
     List.iter
       (fun a ->
         let ca = Listing_spool.cursor cmp in
         while (not (Listing_spool.at_end ca)) && Listing_spool.key ca <> a do
           Listing_spool.advance ca
         done;
         List.iter
           (fun b ->
             let cb = Listing_spool.cursor cmp in
             while
               (not (Listing_spool.at_end cb)) && Listing_spool.key cb <> b
             do
               Listing_spool.advance cb
             done;
             let want = Int.compare (String.compare a b) 0 in
             if Int.compare (Listing_spool.compare ca cb) 0 <> want then
               ok := false)
           adversarial)
       adversarial;
     check "compare matches String.compare on every pair" !ok;

     print_endline "\n=== directory markers";
     let dc = Listing_spool.cursor cmp in
     let dirs =
       let acc = ref [] in
       while not (Listing_spool.at_end dc) do
         if Listing_spool.key_is_dir dc then acc := Listing_spool.key dc :: !acc;
         Listing_spool.advance dc
       done;
       List.rev !acc
     in
     Printf.printf "  %s\n" (String.concat " " dirs);
     check "a trailing slash is read off the mapping" (dirs = ["b/"]);

     print_endline "\n=== the file is gone, the mapping is not";
     let* () = Listing_spool.remove s in
     let after = drain s in
     Printf.printf "  %d record(s) still readable, last %s\n"
       (List.length after)
       (fst (List.nth after (List.length after - 1)));
     check "an unlinked spool still serves the bytes it was mapped from"
       (after = walked);

     let* () = Lwt_list.iter_s Listing_spool.remove [dup; empty; cmp] in
     report ();
     Lwt.return_unit)
