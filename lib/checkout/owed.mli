(** Records this client has written and owes the store.

    A file change writes its own record; sending the bytes is the sync layer's
    work, on workers with a width and a retry policy. This is how the one tells
    the other. *)

module Make (Lock : Lock.S with type 'a io := 'a Lwt.t) : sig
  type t

  val create : unit -> t

  (** Say that [key]'s record is written and owed. Never blocks, and never drops
      what it is told: a signal sent while nobody waits is delivered to whoever
      waits next. *)
  val signal : t -> Journal.Entry_key.t -> Wal.record -> unit

  (** The next owed record, waiting until there is one. *)
  val next : t -> (Journal.Entry_key.t * Wal.record) Lwt.t

  (** How many are waiting to be taken up. *)
  val pending : t -> int
end
