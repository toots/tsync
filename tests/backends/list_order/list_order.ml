(* The order a listing comes back in, which a resync's merge-join rests on.

   {!Backend.S.fold_prefix} promises ascending keys within a prefix, and a diff
   that walks two listings in step produces nonsense the moment one of them is
   not. s3 and gcs answer in key order by contract; a local store walks a
   directory tree, and the order it emits is this file's subject.

   The trap is that a key's order is not its name's. A directory's keys all
   begin with its name and a slash, and '/' is 0x2F -- above '-' and '.', below
   every digit and letter. So a directory [a] belongs *between* the files [a-]
   and [a0], and a walk that sorts its children by bare name puts the whole
   subtree first. That is the one wrong implementation this exists to catch. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "list-order"
let keys entries = List.map (fun e -> e.Backend.key) entries

let write rel body =
  let path = Filename.concat root rel in
  Fs_util.mkdir_p_sync (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc body;
  close_out oc

(* Every pair here is one the naive orderings get wrong: "a-" against the
   subtree "a/", "b/" against the file "b0". *)
let fixture () =
  write "a-" "one";
  write "a/z" "two";
  write "a0" "three";
  write "aa" "four";
  write "b0" "five";
  Fs_util.mkdir_p_sync (Filename.concat root "b");
  write "deep/x/y/f" "six"

let ascending ks =
  let rec go = function
    | a :: (b :: _ as rest) -> String.compare a b < 0 && go rest
    | _ -> true
  in
  go ks

let () =
  Lwt_main.run
    (let store =
       fixture ();
       Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some root)
     in
     let module B = (val store : Backend.S) in
     print_endline "=== the whole store, listed";
     let* listed = B.list_prefix ~prefix:"" () in
     let listed_keys = keys listed in
     List.iter (Printf.printf "  %s\n") listed_keys;
     check "list_prefix comes back ascending" (ascending listed_keys);
     check "the subtree sorts between the files it belongs between"
       (listed_keys = ["a-"; "a/z"; "a0"; "aa"; "b/"; "b0"; "deep/x/y/f"]);
     check "an empty directory surfaces as its marker, in position"
       (List.nth_opt listed_keys 4 = Some "b/");

     print_endline "\n=== the same store, a page at a time";
     let pages = ref [] in
     let* () =
       B.fold_prefix ~prefix:""
         ~f:(fun page ->
           pages := page :: !pages;
           Lwt.return_unit)
         ()
     in
     let pages = List.rev_map keys !pages in
     List.iteri
       (fun i p -> Printf.printf "  page %d: %s\n" i (String.concat " " p))
       pages;
     check "every page is ascending within itself"
       (List.for_all ascending pages);
     check "and each page starts above where the last one ended"
       (ascending (List.concat pages));
     check "the pages concatenate to exactly what list_prefix answered"
       (List.concat pages = listed_keys);
     check "no page is empty" (List.for_all (fun p -> p <> []) pages);

     print_endline "\n=== bounds and edges";
     let* three = B.list_prefix ~max_keys:3 ~prefix:"" () in
     Printf.printf "  max_keys:3 -> %s\n" (String.concat " " (keys three));
     check "max_keys takes the first three in that order"
       (keys three = ["a-"; "a/z"; "a0"]);
     let* one = B.list_prefix ~prefix:"a0" () in
     Printf.printf "  a plain file as the prefix -> %s\n"
       (String.concat " " (keys one));
     check "a prefix that names a file answers with that one object"
       (keys one = ["a0"]);
     let* none = B.list_prefix ~prefix:"nothing-here/" () in
     check "a prefix that names nothing answers with nothing" (none = []);
     let* sub = B.list_prefix ~prefix:"deep/" () in
     Printf.printf "  under deep/ -> %s\n" (String.concat " " (keys sub));
     check "a scoped prefix walks only its own subtree"
       (keys sub = ["deep/x/y/f"]);

     Scratch.cleanup root;
     report ();
     Lwt.return_unit)
