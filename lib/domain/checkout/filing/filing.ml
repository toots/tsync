(* What this needs below it: the two writers a filed child is recorded through.
   Prose for each member lives with the module that implements it. *)
module type FOLDERS = sig
  type 'a io

  val write :
    cache_root:string ->
    domain_name:string ->
    Logical_key.t ->
    Folder.marker ->
    unit io
end

module type MANIFESTS = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val write : Logical_key.t -> Manifest.t -> unit io
  end
end

(* Where a folder's child is filed in the working copy, and under what name.

   Shared because a resync and a browse have to leave the same tree behind: one
   that filed a child differently from the other would answer differently
   depending on which had run last, and every reader below reads only the tree. *)
module Over
    (Io : Io.S)
    (Fi : FOLDERS with type 'a io := 'a Io.t)
    (Mf : MANIFESTS with type 'a io := 'a Io.t) =
struct
  let ( let+ ) x f = Io.map f x

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Manifests = Mf.Make (C)

    (* The name is in the body: the key a child was read by is hashed. *)
    let record ~parent (entry : Inode_tree.entry) =
      match entry.Inode_tree.body with
        | Inode_tree.Dir marker ->
            let key = Logical_key.dir_in parent marker.Folder.name in
            let+ () =
              Fi.write ~cache_root:C.cache_root ~domain_name:C.domain_name key
                marker
            in
            key
        | Inode_tree.File manifest ->
            let key =
              Logical_key.file_in parent (Manifest.recorded_name manifest)
            in
            let+ () = Manifests.write key manifest in
            key
  end
end
