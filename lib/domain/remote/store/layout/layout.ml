(* How a logical manifest key ([domain_prefix ^ real-path]) maps to the key an
   object lives under. Behind one module type, so call sites speak only in
   logical keys through {!Store}. Answers in a monad because the inode scheme
   resolves folder ids from local state. Reads only: bringing a folder into
   existence is a claim on the store, and {!Store} makes it. *)
module type S = sig
  type 'a io

  (** Logical manifest key (or directory prefix) -> backend key, resolving only
      folder ids this client already holds: [None] when one is unknown. *)
  val manifest_key : Logical_key.t -> Stored_key.t option io

  (** A directory's folder marker key, under its parent's namespace. [None] at
      the domain root, for a parent this client holds no id for, or for a layout
      with no folder tree. *)
  val folder_marker_key : Logical_key.t -> Stored_key.t option io

  (** The id naming a directory's own namespace, if this client holds one. *)
  val folder_id : Logical_key.t -> string option io
end

(** The inode scheme for one domain, which is what a consumer takes. *)
module type OVER = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : S with type 'a io := 'a io
end

module Over (Io : Io.S) (Folder_ids : Folder_ids.S with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  (* [manifests/<parent_folder_id>/<hash(leaf)>], the parent id resolved from the
     local [.tsync-dir] markers, so a folder rename never changes its descendants'
     keys. A directory prefix maps to [manifests/<id>/]. *)
  module Inode = struct
    module Make (C : Conf.S with type 'a io = 'a Io.t) :
      S with type 'a io := 'a Io.t = struct
      let folder_id key =
        Folder_ids.lookup_id ~cache_root:C.cache_root ~domain_name:C.domain_name
          key

      let child_key ~folder_id leaf =
        Stored_key.child_key ~prefix:C.domain_prefix ~folder_id leaf

      module Lk = Logical_key.Make (C)

      (* A folder moved here since an op naming it by path was recorded keeps its
         id, and with it its children's keys: the old path answers with the id it
         last named, if that folder still lives somewhere. *)
      let parent_id key =
        let* live = folder_id key in
        match live with
          | Some id -> return_some id
          | None -> (
              let* kept =
                Folder_ids.lookup_id_removed ~cache_root:C.cache_root
                  ~domain_name:C.domain_name key
              in
              match kept with
                | None -> Io.return None
                | Some id ->
                    let+ at =
                      Folder_ids.key_of_id ~cache_root:C.cache_root
                        ~domain_name:C.domain_name ~root:Lk.root id
                    in
                    Option.map (fun _ -> id) at)

      (* A folder is not filed as a manifest — it is named by its marker under the
         parent's namespace — so this resolves a file either way. *)
      let manifest_key key =
        let+ pid = parent_id (Logical_key.parent key) in
        Option.map
          (fun pid -> child_key ~folder_id:pid (Logical_key.leaf key))
          pid

      let folder_marker_key key =
        if Logical_key.is_root key then Io.return None else manifest_key key
    end
  end

  (* The logical key already is the backend key, so callers holding inode-space
     keys and no path (share serving walks the folder tree by id) can reuse the
     path-keyed read machinery. There is no folder tree to record. *)
  module Identity : S with type 'a io := 'a Io.t = struct
    (* This layout's space is the logical spelling itself, so a key is a path
       under no prefix at all. *)
    let of_logical key =
      Stored_key.in_space ~prefix:"" (Logical_key.to_string key)

    let manifest_key key = return_some (of_logical key)
    let folder_marker_key _ = Io.return None

    (* The key already names the namespace; there is no path to resolve. *)
    let folder_id key = return_some (Logical_key.leaf key)
  end
end
