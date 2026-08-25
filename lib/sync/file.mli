(** The domain file operations backed by the local manifest mirror, the staged
    tree and the chunk store. {!File_ops.S} is the interface they satisfy.

    Every file change writes its own journal record and hands it to whoever
    sends the bytes, which is a worker pool with a width and a retry policy of
    its own. That pool is not here; what is here is the record, and the few
    questions the pool asks back. *)

(** What the sending pool needs of the file operations, and what it tells them
    in return. *)
module type Owing = sig
  (** The file a record names, from its ops: a [`Put] or [`Delete] names a file,
      the directory ops a folder. *)
  val record_key : Wal.record -> Logical_key.t option

  (** What a record will cost to send. Only a [`Put] carries bytes. *)
  val record_size : Wal.record -> int64

  (** Send one file's staged content. Called by the pool, not by a frontend. *)
  val upload : ?cancel:bool ref -> Logical_key.t -> unit Lwt.t

  (** Say which files are being sent right now, for
      {!File_ops.S.uploads_in_flight}. *)
  val set_in_flight : (unit -> Logical_key.t list) -> unit

  (** Say how to stop a send. Not only reported: a write to a file being sent
      must stop the send, or a manifest is published for content torn out from
      under it. *)
  val set_canceller : (Logical_key.t -> bool) -> unit
end

module Make_with_layout (C : Conf.S) (L : Layout.S) : sig
  include File_ops.S
  include Owing
end

module Make (C : Conf.S) : sig
  include File_ops.S
  include Owing
end
