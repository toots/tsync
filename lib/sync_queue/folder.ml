(* Backend folder inode model.

   A directory is identified by a stable random [id], not by its (mutable) name,
   so renaming or moving a folder never rewrites its descendants — their keys
   live under [manifests/<id>/…] and that id never changes. Only the parent's
   marker entry (name → child id) is updated.

   Two kinds of object live under [manifests/<folder_id>/<hash(childname)>]:
   a file manifest, or a folder marker ({dir,name,id}) that both names a child
   directory and points at the namespace holding its children. *)

(* Reserved namespace ids share the [.tsync-] sentinel prefix used for internal
   markers, so they never collide with a (random hex) folder id and read as
   internal. *)
let root_id = ".tsync-root"

(* Deleted folders are detached from their parent and their marker moved under
   this namespace (unreachable from root, so they vanish from listings/resync);
   [expire] reclaims the subtree past a grace period. *)
let trash_id = ".tsync-trash"

(* 128-bit random id, minted at mkdir. Xxhash-free: ids are opaque handles. *)
let () = Random.self_init ()

let new_id () =
  Printf.sprintf "%08Lx%08Lx"
    (Random.int64 0x1_0000_0000L)
    (Random.int64 0x1_0000_0000L)

(* A child's key component within its parent's namespace: the dual-seed xxHash
   of its leaf name, matching the chunk-key convention. Fixed length and
   filesystem-safe regardless of the real name. *)
let hash_name name = Xxhash.hash_hex name 0 ^ "-" ^ Xxhash.hash_hex name 1

(* Manifests-relative key of [name] inside folder [folder_id]. *)
let child_key ~folder_id name = folder_id ^ "/" ^ hash_name name

type marker = { name : string; id : string }

let marker_to_string { name; id } =
  Yojson.Basic.to_string
    (`Assoc [("dir", `Bool true); ("name", `String name); ("id", `String id)])

(* A trashed folder's marker additionally records its original path, so it can be
   listed and restored. Extra fields are ignored by {!marker_of_string}. *)
let trash_marker_to_string ~name ~id ~path =
  Yojson.Basic.to_string
    (`Assoc
       [
         ("dir", `Bool true);
         ("name", `String name);
         ("id", `String id);
         ("path", `String path);
       ])

let trash_path_of_string data =
  match Yojson.Basic.from_string data with
    | `Assoc fields -> (
        match List.assoc_opt "path" fields with
          | Some (`String s) -> Some s
          | _ -> None)
    | _ | (exception _) -> None

(* [Some marker] when [data] is a folder marker; [None] for a file manifest. *)
let marker_of_string data =
  match Yojson.Basic.from_string data with
    | `Assoc fields when List.assoc_opt "dir" fields = Some (`Bool true) ->
        let str k =
          match List.assoc_opt k fields with Some (`String s) -> s | _ -> ""
        in
        Some { name = str "name"; id = str "id" }
    | _ -> None
    | exception _ -> None
