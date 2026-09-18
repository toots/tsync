(* A path resolved on the store alone. The files are published the way a client
   publishes them, so what is looked up is where an upload really files a name
   rather than where this test thinks it should. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "tree-find"

module C = (val Fixture.conf ~domain:"testdom" ~chunk_size:4 ~root ())
module Lk = Logical_key.Make (C)
module R = Remote_lwt.Make (C)
module Tree = Inode_tree_lwt.Make (C)

let upload rel contents =
  let src = Filename.concat root "src" in
  let oc = open_out_bin src in
  output_string oc contents;
  close_out oc;
  let+ (_ : Manifest.t) =
    R.upload ~key:(Lk.file rel) ~src_path:src ~mtime:0. ~chunk_size:4 ()
  in
  ()

let find path = Tree.find ~folder_id:Stored_key.root_id path

let names_file name = function
  | `File { Inode_tree.body = Inode_tree.File m; _ } ->
      Manifest.recorded_name m = name
  | _ -> false

let () =
  Lwt_main.run
    (let* () = upload "top.txt" "top" in
     let* () = upload "sub/deep/c é.txt" "charlie" in

     let* found = find ["top.txt"] in
     check "a file at the root" (names_file "top.txt" found);

     let* found = find ["sub"; "deep"; "c é.txt"] in
     check "a file two folders down, its name not plain ASCII"
       (names_file "c é.txt" found);

     let* found = find ["sub"; "deep"] in
     let* listed =
       match found with
         | `Folder id -> Tree.children ~folder_id:id ()
         | _ -> Lwt.return []
     in
     check "a folder answers with the id its children are listed under"
       (List.length listed = 1);

     let* found = find [] in
     check "no names is the folder asked from"
       (found = `Folder Stored_key.root_id);

     let* found = find ["sub"; "nope.txt"] in
     check "a name nobody has" (found = `Missing);

     let* found = find ["top.txt"; "below"] in
     check "a file has nothing under it" (found = `Missing);

     Scratch.cleanup root;
     Lwt.return_unit);
  report ~expected:6 ()
