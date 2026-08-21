module type S = sig
  (** Record the work and queue it. Returns once the record is durable, not once
      the upload has landed. [entry_key] names the record and goes on to name
      the journal entry the upload publishes; the file is read from the record's
      ops, so there is nowhere for the two to disagree about which one this is.

      The whole record is the caller's to supply, so re-queueing one carries
      forward what it has already been through. *)
  val post : entry_key:Journal.Entry_key.t -> Wal.record -> unit Lwt.t

  val cancel_put : string -> bool

  (** Files with an active or queued upload. *)
  val pending : unit -> int

  (** Keys of the files a worker is uploading right now. *)
  val uploading : unit -> string list

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

  val start :
    upload:(key:string -> cancel:bool ref -> unit Lwt.t) ->
    on_upload_done:(key:string -> unit Lwt.t) ->
    unit

  (** Settles the queue. The cursor the drained uploads owe is
      {!File_store.flush_cursor}'s to publish — see {!Domain_engine.drain} for
      the order the two go in. *)
  val drain : unit -> unit Lwt.t
end

module Make (C : Conf.S) : S
