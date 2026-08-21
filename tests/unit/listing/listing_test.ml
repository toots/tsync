(* A listing spilled to disk, against the two things a caller asks of it before
   it can be trusted with a keyspace.

   The first is a total before the walk: a resync announces how much there is to
   do, and nothing downstream gets a second chance to be told. The second is that
   the walk can happen more than once, a run copying the same listing to each of
   its destinations.

   Records carry names, and a name is an arbitrary byte string, so the fields are
   length-prefixed and the case below plants the separators a delimited format
   would have chosen. *)

open Lwt.Syntax
open Check

let dir = Filename.temp_dir "tsync-listing" ""

let entry =
  Listing.create ~dir ~name:"entries" ~decode:(fun body pos ->
      let key = Listing.read_string body pos in
      let name = Listing.read_string body pos in
      (key, name, Listing.read_int64 body pos))

let write t (key, name, size) =
  Listing.add t
    [
      (fun b -> Listing.str b key);
      (fun b -> Listing.str b name);
      (fun b -> Listing.int64 b size);
    ]

let planted =
  [
    ("chunks/000/aaaa", "plain", 1L);
    ("chunks/001/bbbb", "with\nnewline", 0L);
    ("chunks/002/cccc", "with\ttab", Int64.max_int);
    ("chunks/003/dddd", "with\000nul", -1L);
    ("chunks/004/eeee", "", 4096L);
  ]

let () =
  Lwt_main.run
    (let* t = entry in
     let* () = Lwt_list.iter_s (write t) planted in

     case "the total is known before the walk";
     check "count is what went in" (Listing.count t = List.length planted);

     case "a record survives whatever its fields hold";
     let first = ref [] in
     let* () =
       Listing.iter t (fun r ->
           first := r :: !first;
           Lwt.return_unit)
     in
     check "every record reads back exactly as it was written"
       ~why:(fun () ->
         String.concat " | "
           (List.map
              (fun (k, n, s) -> Printf.sprintf "%s/%S/%Ld" k n s)
              (List.rev !first)))
       (List.rev !first = planted);

     (* A run copies the same listing to each of its destinations, so the second
        walk has to see what the first did. *)
     case "the walk can happen again";
     let second = ref [] in
     let* () =
       Listing.iter t (fun r ->
           second := r :: !second;
           Lwt.return_unit)
     in
     check "a second walk sees the same records, in the same order"
       (List.rev !second = planted);
     check "and the count did not move" (Listing.count t = List.length planted);

     (* Appending to a sealed spool is the one mistake the mapping cannot
        survive, so it is refused rather than left to fault a reader. *)
     case "appending after the first walk is refused";
     let* refused =
       Lwt.catch
         (fun () ->
           let+ () = write t ("chunks/005/ffff", "late", 0L) in
           false)
         (function
           | Invalid_argument _ -> Lwt.return_true | exn -> Lwt.fail exn)
     in
     check "add raises once the spool is sealed" refused;
     check "and nothing was counted for it"
       (Listing.count t = List.length planted);

     let+ () = Listing.drop t in
     report ~expected:6 ())
