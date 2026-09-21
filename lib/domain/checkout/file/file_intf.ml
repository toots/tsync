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

(** What the metadata queue needs of the file operations. *)
module type Publishing = sig
  type 'a io

  (** The backend half of ops whose local half the caller has already applied,
      answering the ops to publish in their place. Everything it needs comes
      from the ops, the mirror having moved on, except where a new folder now
      is: it is published there, or not at all if it is gone. *)
  val backend_ops : Journal.op list -> Journal.op list io
end

(** The file operations over one domain, as the Lwt binding builds them: what a
    whole-domain job takes. *)
module type OVER = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    include File_ops.S with type 'a io := 'a io
    include Owing with type 'a io := 'a io
    include Publishing with type 'a io := 'a io
  end
end
