(** Reading the backend's folder tree: from a folder id to its children,
    classified.

    Under the inode layout every child of a folder lives at
    [manifests/<folder_id>/<hash(name)>] and is either a folder marker or a file
    manifest, told apart only by its body. This is the one place that fetches
    and classifies them. *)

include module type of struct
  include Inode_tree_intf
end

module Over
    (Io : Io.S)
    (Pools : Bounded.S with type 'a io := 'a Io.t)
    (_ : Store.INODE with type 'a io := 'a Io.t and type pool := Pools.t) :
  OVER with type 'a io := 'a Io.t and type pool = Pools.t
