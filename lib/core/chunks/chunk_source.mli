(** Where a chunk's bytes come from, decided before any of them are read: a
    caller choosing between these must not do I/O to choose, or every chunk's
    bytes land before anything queues for a buffer.

    ['a] is what filling a buffer answers with, so the scheduler a caller runs
    under stays out of here. *)
type 'a t =
  | Stored of string
      (** Named already, from a manifest this upload inherits. Nothing to hash,
          nothing to send. *)
  | Mapped of (unit -> Bigstring.t)
      (** Bytes produced in place, so the pages reach the store without being
          copied into a buffer first. Run inside the bound, a mapping costing
          memory as a buffer does. *)
  | Filled of { len : int; fill : Bigstring.t -> 'a }
      (** Bytes written into a buffer this supplies. *)
