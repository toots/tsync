open Lwt.Syntax

type kind = [ `Dir | `File | `Symlink ]

type t = {
  self : Item_ref.t;
  parent : Item_ref.t;
  name : string;
  kind : kind;
  size : int;
  mtime : float;
  etag : string;
  is_uploaded : bool;
  symlink : string option;
  trashed : bool;
}

let kind_string = function
  | `Dir -> "dir"
  | `File -> "file"
  | `Symlink -> "symlink"

let fields r =
  [
    ("ref", `String (Item_ref.to_string r.self));
    ("parentRef", `String (Item_ref.to_string r.parent));
    ("name", `String r.name);
    ("kind", `String (kind_string r.kind));
    ("size", `Int r.size);
    ("mtime", `Float r.mtime);
    ("etag", `String r.etag);
    ("isUploaded", `Bool r.is_uploaded);
  ]
  @ (match r.symlink with
    | None -> []
    | Some t -> [("symlinkTarget", `String t)])
  @ if r.trashed then [("trashed", `Bool true)] else []

let to_json r = `Assoc (fields r)

(* A directory reports mtime zero and its own id as etag, both constant for the
   folder's lifetime, so a caller watching for change is not told a directory
   just changed on every look. *)
let dir_row ~self ~parent ~name id =
  {
    self;
    parent;
    name;
    kind = `Dir;
    size = 0;
    mtime = 0.;
    etag = id;
    is_uploaded = true;
    symlink = None;
    trashed = false;
  }

let dir_with_id = dir_row

module Make (C : Conf_lwt.S) (F : File_ops.S with type 'a io := 'a Lwt.t) =
struct
  module Lk = Logical_key.Make (C)

  let lookup_folder key =
    if Logical_key.is_root key then Lwt.return_some Stored_key.root_id
    else
      Folder_ids_lwt.lookup_id ~cache_root:C.cache_root
        ~domain_name:C.domain_name key

  (* Naming a removal is the one read that must answer after the mirror has
     dropped the folder, so it asks the store that keeps an id past its marker. *)
  let removed_folder_id key =
    if Logical_key.is_root key then Lwt.return_some Stored_key.root_id
    else
      Folder_ids_lwt.lookup_id_removed ~cache_root:C.cache_root
        ~domain_name:C.domain_name key

  (* For a directory key: the id of the folder [key] is. *)
  let own_folder_id key = lookup_folder key

  (* The id of the folder [key] sits in. *)
  let parent_folder_id key = lookup_folder (Logical_key.parent key)

  (* [container_id] is passed in because a listing resolves the folder once and
     reuses it for every file under it: a directory costs one marker read for
     its own id, a file one for its parent's. *)
  let self_ref ~container_id key =
    let body = Logical_key.path key in
    if body = "" then Lwt.return_some `Root
    else if Logical_key.kind key = `Dir then
      let+ id =
        Folder_ids_lwt.lookup_id ~cache_root:C.cache_root
          ~domain_name:C.domain_name key
      in
      Option.map (fun id -> `Dir id) id
    else Lwt.return_some (`File (container_id, Logical_key.leaf key))

  let parent_ref container_id =
    if container_id = Stored_key.root_id then `Root else `Dir container_id

  (* [None] for an item under a folder this client holds no id for, which cannot
     be named to a caller at all. *)
  let naming ~container_id key =
    let name =
      if Logical_key.path key = "" then C.domain_name else Logical_key.leaf key
    in
    let+ self = self_ref ~container_id key in
    Option.map (fun self -> (self, parent_ref container_id, name)) self

  let file_row ~self ~parent ~name ~size ~mtime ~etag ~is_uploaded ~symlink =
    {
      self;
      parent;
      name;
      kind = (match symlink with None -> `File | Some _ -> `Symlink);
      size;
      mtime;
      etag;
      is_uploaded;
      symlink;
      trashed = false;
    }

  let published_row ~self ~parent ~name m =
    file_row ~self ~parent ~name
      ~size:(Int64.to_int (Manifest.size m))
      ~mtime:(Manifest.mtime m) ~etag:(Manifest.h1 m) ~is_uploaded:true
      ~symlink:(Manifest.symlink m)

  (* The kind comes from the mirror rather than from how the key was spelled: a
     key says what an item is called and not which kind it is, and whoever holds
     one holds the tree that answers that. *)
  let item_ref key =
    let* kind = F.kind key in
    let key =
      let rel = Logical_key.path key in
      match kind with
        | `Dir -> Lk.dir rel
        | `File -> Lk.file rel
        | `Absent -> key
    in
    let* container = parent_folder_id key in
    let container_id = Option.value container ~default:Stored_key.root_id in
    let+ self = self_ref ~container_id key in
    Option.map Item_ref.to_string self

  let of_key ?(expect = `Any) key =
    let* kind = F.kind key in
    let is_dir = kind = `Dir in
    if (expect = `File && is_dir) || (expect = `Dir && not is_dir) then
      Lwt.return_none
    else
      let* container = parent_folder_id key in
      let container_id = Option.value container ~default:Stored_key.root_id in
      let* named = naming ~container_id key in
      match named with
        | None -> Lwt.return_none
        | Some (self, parent, name) -> (
            if is_dir then
              let+ own = own_folder_id key in
              Option.map (dir_row ~self ~parent ~name) own
            else
              (* The staged manifest is authoritative for size and mtime until
                 the upload publishes. *)
              let* staged = F.resolve key in
              match staged with
                | Some (`Staged (st, _)) ->
                    Lwt.return_some
                      (file_row ~self ~parent ~name
                         ~size:(Int64.to_int st.Staged_manifest.s_size)
                         ~mtime:st.Staged_manifest.s_mtime ~etag:""
                         ~is_uploaded:false ~symlink:None)
                | Some (`Published _) | None ->
                    let+ m = F.published key in
                    Option.map (published_row ~self ~parent ~name) m)

  let of_dir ~container_id key =
    let* named = naming ~container_id key in
    match named with
      | None -> Lwt.return_none
      | Some (self, parent, name) ->
          let+ id = own_folder_id key in
          Option.map (dir_row ~self ~parent ~name) id

  let of_listed ~container_id (e : Checkout.listed) =
    let key = e.Checkout.key in
    let* named = naming ~container_id key in
    match named with
      | None -> Lwt.return_none
      | Some (self, parent, name) ->
          let+ m = F.published key in
          Some
            (match m with
              | Some m -> published_row ~self ~parent ~name m
              | None ->
                  file_row ~self ~parent ~name ~size:e.Checkout.size
                    ~mtime:e.Checkout.mtime ~etag:"" ~is_uploaded:true
                    ~symlink:None)
end
