(** The domain file operations backed by the local manifest mirror, the staged
    tree and the chunk store. {!File_ops.S} is the interface they satisfy.

    Every file change writes its own journal record and hands it to whoever
    sends the bytes, which is a worker pool with a width and a retry policy of
    its own. That pool is not here; what is here is the record, and the few
    questions the pool asks back. *)

include module type of struct
  include File_intf
end

module Over
    (Io : Io.S)
    (_ : Fs.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : Lock.S with type 'a io := 'a Io.t)
    (_ : Wal.OVER with type 'a io := 'a Io.t)
    (_ : Manifests.OVER with type 'a io := 'a Io.t)
    (_ : Checkout.OVER with type 'a io := 'a Io.t)
    (_ : Staged_manifest.OVER with type 'a io := 'a Io.t)
    (_ : Data.OVER with type 'a io := 'a Io.t)
    (_ : Folder_ids.S with type 'a io := 'a Io.t) : sig
  (** {1 What the store is asked for}

      Signatures rather than the modules that satisfy them, so the operations
      are written against what they call and not against a store:
      {!File_store.Make}, {!Store.Make} and {!History.Make} each answer one, and
      {!Remote.S} is taken whole because {!Data.Make} is given it. {!Make} is
      where they are built. *)

  (** What the sending pool needs of the file operations, and what it tells them
      in return. *)

  (** [L] is still taken: a folder's id is resolved here, not by the store. *)
  module Make_with_layout
      (C : Conf.S with type 'a io = 'a Io.t)
      (L : Layout.S with type 'a io := 'a Io.t)
      (_ : File_store.S with type 'a io := 'a Io.t)
      (_ : Store.S with type 'a io := 'a Io.t)
      (_ : History.S with type 'a io := 'a Io.t)
      (_ : Remote.S with type 'a io := 'a Io.t) : sig
    include File_ops.S with type 'a io := 'a Io.t
    include Owing with type 'a io := 'a Io.t
    include Publishing with type 'a io := 'a Io.t
  end
end
