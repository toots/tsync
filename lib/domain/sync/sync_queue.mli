(** What this needs below it. *)
module type S = sig
  type 'a io

  val cancel_put : string -> bool

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
end

module type JOURNAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val write_journal_entry :
      ?entry_key:Journal.Entry_key.t ->
      Journal.op list ->
      Journal.Entry_key.t io

    val note_cursor : Journal.Entry_key.t -> unit
  end
end

module type QUEUE = sig
  type 'a io
  type t

  module Records : sig
    type t
  end

  val keyed :
    ?max_queued:int ->
    ?workers:int ->
    ?weight:(Wal.record -> int64) ->
    name:string ->
    log:Records.t ->
    key:(Wal.record -> string) ->
    classify:(exn -> Retry.kind) ->
    poison:Durable_queue.poison ->
    run:(id:string -> Wal.record -> cancel:bool ref -> unit io) ->
    unit ->
    t

  val post : ?id:string -> t -> Wal.record -> unit io
  val adopt : t -> id:string -> Wal.record -> unit io
  val start : ?recover:bool -> t -> unit
  val cancel : t -> string -> bool
  val set_paused : t -> bool -> unit
  val paused : t -> bool
  val stop : t -> unit io
  val stats : t -> Durable_queue.stats
  val in_flight : t -> Wal.record list
  val owed : t -> int
end

module type WAL = sig
  type 'a io
  type records

  module Owed : sig
    type 'a t

    val consume : 'a t -> ('a -> unit io) -> unit
    val idle : 'a t -> unit
  end

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val log : records
    val owed : (Journal.Entry_key.t * Wal.record) Owed.t
    val complete : Journal.Entry_key.t -> unit io
    val note_failure : Journal.Entry_key.t -> Retry.kind -> string -> unit io

    val discharge :
      publish:(Journal.Entry_key.t -> Journal.op list -> Journal.Entry_key.t io) ->
      cursor:(Journal.Entry_key.t -> unit io) ->
      Journal.Entry_key.t ->
      Journal.op list ->
      unit io
  end
end

module Over
    (Io : Io.S)
    (_ : JOURNAL with type 'a io := 'a Io.t)
    (Q : QUEUE with type 'a io := 'a Io.t)
    (_ : WAL with type 'a io := 'a Io.t and type records := Q.Records.t) : sig
  (** The sending half of a domain: it takes up the records the file operations
      write and hand over, and drains them to the store on a pool of its own.
      The records are not its own — they are written before it hears of them,
      which is what makes a crash leave something saying the work is owed. *)
  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File.Owing with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t
end
