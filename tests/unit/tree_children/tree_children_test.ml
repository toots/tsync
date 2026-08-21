(* What a folder's children cost the walk that reads them.

   An emptied namespace lists as its own directory key, and a GET of one fails
   outright: the resync that counted that as a broken child never advanced its
   bookmark, so every later sync resynced the whole domain again. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "tree-children"

module Store =
  (val Backend.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Store : Backend.S)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf.S)

module Tree = Inode_tree.Make (C)

let ns id = C.domain_prefix ^ id ^ "/"
let put id name body = Store.put ~key:(ns id ^ name) ~data:(Chunk.of_string body) ()

let manifest_body name =
  Chunk_table.encode ~name ~size:0L ~chunk_size:4 ~mtime:0.
    ~h1:(String.make 16 'a') ~h2:(String.make 16 'b') ~symlink:None ~keys:[]

let is_file = function
  | { Inode_tree.body = Inode_tree.File _; _ } -> true
  | _ -> false

let is_dir = function
  | { Inode_tree.body = Inode_tree.Dir _; _ } -> true
  | _ -> false

let () =
  Lwt_main.run
    (case "an emptied namespace has no children";
     let emptied = Folder.new_id () in
     let* () = put emptied "gone" (manifest_body "gone.txt") in
     let* () = Store.delete ~key:(ns emptied ^ "gone") () in
     let* listed = Store.list_prefix ~prefix:(ns emptied) () in
     (* The directory key is what the walk used to choke on, so a run where the
        store stopped listing one would prove nothing. *)
     check "the store still lists the namespace as a directory key"
       (List.exists
          (fun (e : Backend.file_entry) -> Key.is_dir e.Backend.key)
          listed);
     let* children = Tree.children ~folder_id:emptied () in
     check "and it yields no children" (children = []);

     case "children are classified by their body";
     let mixed = Folder.new_id () in
     let* () = put mixed "a" (manifest_body "a.txt") in
     let* () =
       put mixed "b"
         (Folder.marker_to_string { Folder.name = "sub"; id = Folder.new_id () })
     in
     let* children = Tree.children ~folder_id:mixed () in
     check "one manifest" (List.length (List.filter is_file children) = 1);
     check "one marker" (List.length (List.filter is_dir children) = 1);

     case "an unusable body is reported, not raised";
     let junk = Folder.new_id () in
     let* () = put junk "a" (manifest_body "a.txt") in
     let* () = put junk "bad" "neither a marker nor a manifest" in
     let seen = ref [] in
     let* children =
       Tree.children
         ~on_unusable:(`Skip (fun bkey r -> seen := (bkey, r) :: !seen))
         ~folder_id:junk ()
     in
     check "the good child survives" (List.length children = 1);
     check "the bad one is reported once"
       (match !seen with
         | [(bkey, `Unclassifiable _)] -> bkey = ns junk ^ "bad"
         | _ -> false);

     (* [`Fail] is about a fetch that failed; a body that will not parse is a
        write in flight either way. *)
     let* children = Tree.children ~folder_id:junk () in
     check "and `Fail skips it just the same" (List.length children = 1);
     Lwt.return_unit);
  report ~expected:7 ()
