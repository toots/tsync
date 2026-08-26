(** Folders that were deleted, and putting one back.

    A removed folder's marker is moved under {!Stored_key.trash_id}, unreachable
    from the root, so its subtree leaves listings and resync without anything
    being copied or deleted. Restoring is the same move in reverse and costs one
    object write either way, whatever the subtree holds.

    Purging one is {!Expire.purge_trashed}: dropping the versions is what makes
    the chunks collectable, and only that side knows the grace period.

    Nothing here records a journal entry, so a peer learns of a restore by
    resyncing rather than by replay — which is why a caller should say so. *)
type outcome =
  | Restored
  | Not_in_trash
  | Parent_unknown
      (** The folder is there, but this client has no id recorded for the parent
          it would go back under, so there is no key to write. A sync resolves
          the parent and makes the restore possible. *)

(** The key scheme a caller holding real paths wants. *)
module type INODE_LAYOUT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) :
    Layout.S with type 'a io := 'a io
end

(** Writing and removing a folder marker by the key it already has. *)
module type MANIFESTS = sig
  type 'a io

  module Make
      (_ : Conf.S with type 'a io = 'a io)
      (_ : Layout.S with type 'a io := 'a io) : sig
    val put_raw : bkey:Stored_key.t -> data:string -> unit io
    val delete_raw : bkey:Stored_key.t -> unit io
  end
end

module Over
    (Io : Io.S)
    (_ : INODE_LAYOUT with type 'a io := 'a Io.t)
    (_ : MANIFESTS with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** The domain-relative path of every trashed folder. A marker whose body
        does not name one is passed over: a body that will not parse is a write
        in flight, not a finding. *)
    val list : unit -> string list Io.t

    (** Put [path] back where it was. The subtree is untouched. *)
    val restore : string -> outcome Io.t
  end
end
