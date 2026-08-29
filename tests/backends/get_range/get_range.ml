(* What a store owes a range read, asked of the one store a test can run
   against for real. The cloud drivers answer the same questions in
   {!Conformance}, where there is a bucket to ask.

   The bytes are held against the same slice taken locally, not merely counted:
   a store answering the right number of bytes from the wrong offset is the
   failure a length alone cannot see. *)

open Lwt.Syntax

let root = Scratch.dir "get_range"
let k name = Stored_key.in_space ~prefix:"tsync/d/chunks/" name

(* Position-dependent, so a slice from the wrong offset cannot pass. *)
let body =
  let n = 40 in
  let b = Bigstring.create n in
  for i = 0 to n - 1 do
    Bigstringaf.unsafe_set b i (Char.chr (Char.code 'a' + (i mod 26)))
  done;
  b

let size = Bigstring.length body

let () =
  let module B = (val Fixture.local_store root : Backend_lwt.Store) in
  Lwt_main.run
    (let* () = B.put ~key:(k "obj") ~data:body () in
     print_endline "=== a store answers exactly the range asked for";
     let ask ~offset ~length =
       let+ got = B.get_range ~key:(k "obj") ~offset ~length () in
       let describe =
         match got with
           | None -> "None"
           | Some got ->
               let n = Bigstring.length got in
               let want =
                 max 0 (min length (size - min offset size))
               in
               Printf.sprintf "%d bytes, %s" n
                 (if n <> want then "WRONG LENGTH"
                  else if
                    Bigstring.to_string got
                    = String.sub (Bigstring.to_string body) (min offset size)
                        want
                  then "matches"
                  else "WRONG BYTES")
       in
       Printf.printf "  [%d,%d) of %d -> %s\n" offset (offset + length) size
         describe
     in
     let* () = ask ~offset:0 ~length:8 in
     let* () = ask ~offset:13 ~length:9 in
     let* () = ask ~offset:(size - 4) ~length:4 in
     let* () = ask ~offset:0 ~length:size in
     print_endline "";
     print_endline "=== the object's end is where an answer runs short";
     (* Short rather than an error: a reader asks for a whole chunk without
        first learning how long the last one is. *)
     let* () = ask ~offset:(size - 3) ~length:100 in
     let* () = ask ~offset:(size + 10) ~length:8 in
     print_endline "";
     print_endline "=== a key the store does not hold";
     let+ missing = B.get_range ~key:(k "nope") ~offset:0 ~length:8 () in
     Printf.printf "  absent key -> %s\n"
       (match missing with None -> "None" | Some _ -> "SOME"));

  print_endline "";
  print_endline "=== a store that ignored the range is refused, not trimmed";
  (* The check every driver applies to its own answer. A store handing back the
     whole object satisfies its caller -- the bytes it wanted are in there --
     while costing exactly what the range exists to avoid, so nothing downstream
     would ever report it. *)
  let held ~length body =
    match Backend.checked_range ~op:"test" ~key:"obj" ~length body with
      | body -> Printf.sprintf "%d bytes" (Bigstring.length body)
      | exception Backend.Backend_error why -> "refused: " ^ why
  in
  Printf.printf "  asked 8, answered 8    -> %s\n"
    (held ~length:8 (Bigstring.sub body ~off:0 ~len:8));
  Printf.printf "  asked 8, answered 3    -> %s\n"
    (held ~length:8 (Bigstring.sub body ~off:0 ~len:3));
  Printf.printf "  asked 8, answered %d   -> %s\n" size (held ~length:8 body)
