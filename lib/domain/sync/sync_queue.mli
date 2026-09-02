(** What this needs below it. *)
module type S = sig
  type 'a io

  (** Files with an active or queued upload. *)
  val pending : unit -> int

  (** The files a worker is uploading right now. *)
  val uploading : unit -> Logical_key.t list

  (** Bytes still owed: everything queued plus everything in flight. Counted
      whole per file, so a file half sent still counts for its full size. *)
  val pending_bytes : unit -> int64

  (** Uploads completed since the daemon started. *)
  val completed_count : unit -> int

  (** Park the workers between uploads. Queued work is kept, so {!pending} keeps
      reporting it, and {!drain} still runs to completion. Not persisted: a
      restart resumes. *)
  val set_paused : bool -> unit

  val paused : unit -> bool

  (** Start the workers and begin taking up records as they are handed over.
      What is uploaded and how to cancel one come from the file operations this
      is built on, so only the completion callback is passed. *)
  val start : on_upload_done:(key:Logical_key.t -> unit io) -> unit

  (** Settles the queue. The cursor the drained uploads owe is
      {!File_store.flush_cursor}'s to publish — see {!Domain_engine.drain} for
      the order the two go in. *)
  val drain : unit -> unit io

  (** Wait for what is owed under one key to be sent, or to start failing,
      leaving the queue running: for a caller that wants its own write published
      before it goes on, and nobody else's. *)
  val wait_uploaded : Logical_key.t -> unit io
end

(** {!S} over a domain's conf and its file operations: what a consumer takes. *)
module type OVER = sig
  type 'a io

  module Make
      (_ : Conf.S with type 'a io = 'a io)
      (_ : File.Owing with type 'a io := 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (_ : File_store.OVER with type 'a io := 'a Io.t)
    (Q :
      Durable_queue.QUEUE with type 'a io := 'a Io.t and type job := Wal.record)
    (_ : Wal.OVER with type 'a io := 'a Io.t and type records := Q.Records.t) : sig
  (** The sending half of a domain: it takes up the records the file operations
      write and hand over, and drains them to the store on a pool of its own.
      The records are not its own — they are written before it hears of them,
      which is what makes a crash leave something saying the work is owed. *)
  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File.Owing with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t
end
