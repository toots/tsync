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

(* One key that will not read, so the batch fails whole and the walk has to
   decide what that costs its siblings. A wrapper rather than a chmod: the suite
   must behave the same as root. *)
let broken = ref ""

module Flaky : Backend.S = struct
  include Store

  let refuse key = Lwt.fail (Backend.Backend_error ("cannot read " ^ key))
  let get ~key () = if key = !broken then refuse key else Store.get ~key ()

  let get_opt ~key () =
    if key = !broken then refuse key else Store.get_opt ~key ()

  let get_many = None
end

module Cf =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Flaky : Backend.S)
         ~cache_root:root ~data_dir:root ~root ()
      : Conf.S)

module Tf = Inode_tree.Make (Cf)

let ns id = C.domain_prefix ^ id ^ "/"

let put id name body =
  Store.put ~key:(ns id ^ name) ~data:(Bigstring.of_string body) ()

let manifest_body name =
  Manifest.encode ~name ~size:0L ~chunk_size:4 ~mtime:0.
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
     let emptied = Stored_key.new_id () in
     let* () = put emptied "gone" (manifest_body "gone.txt") in
     let* () = Store.delete ~key:(ns emptied ^ "gone") () in
     let* listed = Store.list_prefix ~prefix:(ns emptied) () in
     (* The directory key is what the walk used to choke on, so a run where the
        store stopped listing one would prove nothing. *)
     check "the store still lists the namespace as a directory key"
       (List.exists
          (fun (e : Backend.file_entry) -> Stored_key.is_dir_key e.Backend.key)
          listed);
     let* children = Tree.children ~folder_id:emptied () in
     check "and it yields no children" (children = []);

     case "children are classified by their body";
     let mixed = Stored_key.new_id () in
     let* () = put mixed "a" (manifest_body "a.txt") in
     let* () =
       put mixed "b"
         (Folder.marker_to_string
            { Folder.name = "sub"; id = Stored_key.new_id () })
     in
     let* children = Tree.children ~folder_id:mixed () in
     check "one manifest" (List.length (List.filter is_file children) = 1);
     check "one marker" (List.length (List.filter is_dir children) = 1);

     case "an unusable body is reported, not raised";
     let junk = Stored_key.new_id () in
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

     case "one object that will not read does not cost its siblings";
     let flaky = Stored_key.new_id () in
     let* () = put flaky "good" (manifest_body "good.txt") in
     let* () = put flaky "other" (manifest_body "other.txt") in
     let* () = put flaky "nope" (manifest_body "nope.txt") in
     broken := ns flaky ^ "nope";
     let seen = ref [] in
     let* children =
       Tf.children
         ~on_unusable:(`Skip (fun bkey r -> seen := (bkey, r) :: !seen))
         ~folder_id:flaky ()
     in
     check "the readable siblings still arrive" (List.length children = 2);
     check "and only the unreadable one is reported"
       (match !seen with
         | [(bkey, `Unreadable _)] -> bkey = !broken
         | _ -> false);
     (* A walk deciding what to delete must not take a failed read for an
        absent subtree. *)
     let* refused =
       Lwt.catch
         (fun () ->
           let+ _ = Tf.children ~folder_id:flaky () in
           false)
         (fun _ -> Lwt.return_true)
     in
     check "`Fail refuses the folder rather than shortening it" refused;
     broken := "";
     Lwt.return_unit);
  report ~expected:10 ()
