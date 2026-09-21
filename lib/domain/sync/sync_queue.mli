(** What this needs below it. *)
module type S = Sync_queue_intf.S

(** {!S} over a domain's conf and its file operations: what a consumer takes. *)
module type OVER = Sync_queue_intf.OVER

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
