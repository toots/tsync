(** The domain file operations backed by the local manifest mirror, the staged
    tree and the chunk store. {!File_ops.S} is the interface they satisfy.

    Every file change writes its own journal record and hands it to whoever
    sends the bytes, which is a worker pool with a width and a retry policy of
    its own. That pool is not here; what is here is the record, and the few
    questions the pool asks back. *)

module type Owing = sig
  type 'a io

  (** The file a record names, from its ops: a [`Put] or [`Delete] names a file,
      the directory ops a folder. *)
  val record_key : Wal.record -> Logical_key.t option

  (** What a record will cost to send. Only a [`Put] carries bytes. *)
  val record_size : Wal.record -> int64

  (** Send one file's staged content. Called by the pool, not by a frontend. *)
  val upload : ?cancel:bool ref -> Logical_key.t -> unit io

  (** Say which files are being sent right now, for
      {!File_ops.S.uploads_in_flight}. *)
  val set_in_flight : (unit -> Logical_key.t list) -> unit

  (** Say how to stop a send. Not only reported: a write to a file being sent
      must stop the send, or a manifest is published for content torn out from
      under it. *)
  val set_canceller : (Logical_key.t -> bool) -> unit
end

(** The file operations over one domain, as the Lwt binding builds them: what a
    whole-domain job takes. *)
module type OVER = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    include File_ops.S with type 'a io := 'a io
    include Owing with type 'a io := 'a io
  end
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
  end
end
