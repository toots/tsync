(** Keeping chunks in a store: naming bytes, and not sending what is already
    there.

    A chunk's name is the hash of its bytes, so naming and storing are one act
    and cannot be split without leaving "re-hash after you mutate" as a rule
    each caller has to remember. {!store} is that act: it names the bytes,
    decides whether the store already holds them, writes when it does not, and
    answers with the name either way.

    It asks nothing about where a chunk is kept beyond what {!DEPS} supplies, so
    a collection moving the keyspace underneath it is invisible here. *)

(** Where a chunk's bytes come from, decided before any of them are read: a
    caller choosing between these must not do I/O to choose, or every chunk's
    bytes land before anything queues for a buffer. *)
type source =
  | Stored of string
      (** Named already, from a manifest this upload inherits. Nothing to hash,
          nothing to send. *)
  | Mapped of (unit -> Bigstring.t)
      (** Bytes produced in place, so the pages reach the store without being
          copied into a buffer first. Run inside the bound, a mapping costing
          memory as a buffer does. *)
  | Filled of { len : int; fill : Bigstring.t -> unit Lwt.t }
      (** Bytes written into a buffer this supplies. *)

(** What the store needs of the domain below it. Presence rather than an entry:
    the only thing asked of a store is whether it holds a key, and answering
    less keeps the backend's vocabulary out of this one. *)
module type DEPS = sig
  val put : key:string -> data:Bigstring.t -> unit -> unit Lwt.t

  (** Where a chunk key is written. *)
  val backend_key : string -> string

  (** Whether the store holds it, wherever a collection may have left it. *)
  val present : string -> bool Lwt.t

  val fetch_body : string -> Bigstring.t Lwt.t

  (** Whether the store filed this key as not holding what its name says, and
      how to stop holding it against the rest of the session once a write has
      cleared it — a write is what clears a marker, the store having re-verified
      the object as it took it. *)
  val corrupt : string -> bool Lwt.t

  val cleared : string -> unit

  (** Bytes in flight, and reads in flight. Held here rather than per caller so
      one device and one memory budget bound every route in. *)
  val slots : Lwt_bounded.t

  val downloads : Lwt_bounded.t
  val max_known : unit -> int
end

module Make (_ : DEPS) : sig
  (** The chunk's name, and whether this call is what sent it — a deduplicated
      chunk is as done as a written one and cost no transfer, which is why the
      two are told apart rather than summed. *)
  val store : source -> (string * bool) Lwt.t

  val fetch : string -> Bigstring.t Lwt.t

  (** Keys this session has spared itself a round trip on. *)
  val known_count : unit -> int
end
