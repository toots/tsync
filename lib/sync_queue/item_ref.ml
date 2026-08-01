(* How a frontend names an item to the daemon.

   A path is the wrong name for a directory: renaming one would change what every
   item beneath it is called. Directories already have an id a rename does not
   touch ({!Folder}), so that is what names them here.

   A file is named by its parent's id and its own leaf, which changes on a rename
   exactly as a path would — a deliberate limit, since the storage layout gives a
   file no id of its own. The blast radius is one item rather than a subtree.

   The forms are:

     "root"                  the domain root
     "d:<folder id>"         a directory
     "f:<folder id>/<leaf>"  a file or symlink, by its parent and name
     anything else           a logical key, for the callers that predate this

   Nothing here spells a storage key, so a frontend need not know the layout, and
   nothing spells a user's path, which matters because these reach system logs. *)

open Lwt.Syntax

type t =
  [ `Root
  | `Dir of string
  | `File of string * string  (** parent folder id, leaf name *)
  | `Key of string
  | `Bad of string ]

let dir_prefix = "d:"
let file_prefix = "f:"
let root_form = "root"

let has_prefix p s =
  String.length s > String.length p && String.starts_with ~prefix:p s

let drop_prefix p s =
  String.sub s (String.length p) (String.length s - String.length p)

(* Total: an unparseable reference is a value, so the caller answers with an
   error rather than the request failing. *)
let parse s =
  if s = root_form then `Root
  else if has_prefix dir_prefix s then (
    let id = drop_prefix dir_prefix s in
    if id = Folder.root_id then `Root else `Dir id)
  else if has_prefix file_prefix s then (
    let rest = drop_prefix file_prefix s in
    (* Neither a leaf name nor a folder id can contain "/", so the first one
       separates them. *)
      match String.index_opt rest '/' with
      | None -> `Bad s
      | Some i ->
          let id = String.sub rest 0 i in
          let name = String.sub rest (i + 1) (String.length rest - i - 1) in
          if id = "" || name = "" then `Bad s else `File (id, name))
  else `Key s

let to_string = function
  | `Root -> root_form
  | `Dir id -> dir_prefix ^ id
  | `File (id, name) -> file_prefix ^ id ^ "/" ^ name
  | `Key k -> k
  | `Bad s -> s

module Make (C : Conf.S) = struct
  let rel_of_id id =
    Folder_ids.rel_of_id ~cache_root:C.cache_root ~domain_name:C.domain_name id

  let lookup_id rel =
    Folder_ids.lookup_id ~cache_root:C.cache_root ~domain_name:C.domain_name rel

  let key_of_rel rel = C.domain_prefix ^ rel

  let dir_key_of_rel rel =
    if rel = "" then C.domain_prefix else key_of_rel rel ^ "/"

  (* [None] when nothing is there any more — the point of the scheme: a caller is
     told a directory is gone rather than handed a path resolving to whatever now
     sits there. *)
  let resolve = function
    | `Root -> Lwt.return_some C.domain_prefix
    | `Dir id ->
        let+ rel = rel_of_id id in
        Option.map dir_key_of_rel rel
    | `File (id, name) ->
        let+ rel = rel_of_id id in
        Option.map (fun rel -> key_of_rel (Key.join rel name)) rel
    | `Key k -> Lwt.return_some k
    | `Bad _ -> Lwt.return_none

  (* Resolves only what this client records and mints nothing: naming is a
     read. *)
  let of_key key =
    let rel = Key.strip_prefix ~domain_prefix:C.domain_prefix key in
    let body = Key.chop_slash rel in
    if body = "" then Lwt.return_some `Root
    else if Key.is_dir rel then
      let+ id = lookup_id body in
      Option.map (fun id -> `Dir id) id
    else
      let+ pid = lookup_id (Key.parent body) in
      Option.map (fun pid -> `File (pid, Filename.basename body)) pid

  (* The reference naming the container [key] sits in. *)
  let parent_of_key key =
    let rel = Key.strip_prefix ~domain_prefix:C.domain_prefix key in
    let parent = Key.parent (Key.chop_slash rel) in
    if parent = "" then Lwt.return_some `Root
    else
      let+ id = lookup_id parent in
      Option.map (fun id -> `Dir id) id
end
