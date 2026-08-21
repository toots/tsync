(* Claiming a name: what {!Backend.put_if_absent} has to guarantee.

   A folder id is decided by whoever wins one of these, so a second winner is a
   second namespace and a stranded file. Everything the naming layer does rests
   on this, which is why it is worth pinning down on its own rather than only
   through the two-client scenario that consumes it.

   The local backend stands in for all of them: its claim is a [link], the
   object stores use a write precondition, and an http-proxy asks whoever holds
   the store. What is asserted is the contract they share. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "claim"

let () =
  let (module B : Backend.S) =
    Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some root) ()
  in
  Lwt_main.run
    (case "several clients reach for one name at once";
     (* Started together and resolved together: whichever lands first, the rest
        have to be told about it rather than quietly replacing it. *)
     let* answers =
       Lwt_list.map_p
         (fun i ->
           B.put_if_absent ~key:"claimed"
             ~data:(Chunk.of_string (Printf.sprintf "client%d" i))
             ())
         [1; 2; 3; 4; 5]
     in
     let answers = List.map Chunk.to_string answers in
     let* stored = B.get ~key:"claimed" () in
     let stored = Chunk.to_string stored in
     step "claimants: %d" (List.length answers);
     step "distinct answers: %d" (List.length (List.sort_uniq compare answers));
     step "every answer is what the store holds: %b"
       (List.for_all (fun a -> a = stored) answers);

     case "a later claim on a taken name";
     let* answer =
       B.put_if_absent ~key:"claimed" ~data:(Chunk.of_string "latecomer") ()
     in
     let answer = Chunk.to_string answer in
     let* after = B.get ~key:"claimed" () in
     let after = Chunk.to_string after in
     step "answered with the holder rather than itself: %b"
       (answer = stored && answer <> "latecomer");
     step "the holder is untouched: %b" (after = stored);

     case "a free name";
     let* answer =
       B.put_if_absent ~key:"free" ~data:(Chunk.of_string "mine") ()
     in
     let answer = Chunk.to_string answer in
     let* stored = B.get ~key:"free" () in
     let stored = Chunk.to_string stored in
     step "answered with its own body: %b" (answer = "mine");
     step "and that is what landed: %b" (stored = "mine");

     case "a name released, then claimed again";
     let* () = B.delete ~key:"free" () in
     let* answer =
       B.put_if_absent ~key:"free" ~data:(Chunk.of_string "second") ()
     in
     step "the next claimant wins it: %b" (Chunk.to_string answer = "second");

     (* A claim leaves nothing behind: the losers' bodies were written to their
        own temp files, and a leftover would eventually fill the store. *)
     case "nothing left over";
     let+ entries = B.list_prefix ~prefix:"" () in
     step "objects after all of that: %d"
       (List.length
          (List.filter
             (fun (e : Backend.file_entry) ->
               not
                 (String.length e.key > 0
                 && e.key.[String.length e.key - 1] = '/'))
             entries)));
  Lwt_main.run (Fs_util.rm_rf root)
