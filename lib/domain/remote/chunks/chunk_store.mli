(** Keeping chunks in a store: naming bytes, and not sending what is already
    there.

    A chunk's name is the hash of its bytes, so naming and storing are one act
    and cannot be split without leaving "re-hash after you mutate" as a rule
    each caller has to remember. {!Over.Make.store} is that act: it names the
    bytes, decides whether the store already holds them, writes when it does
    not, and answers with the name either way.

    It asks nothing about where a chunk is kept beyond what {!Over.DEPS}
    supplies, so a collection moving the keyspace underneath it is invisible
    here. *)

(** The bound on what runs at once. Only [use] is asked for: this decides what
    to hold a slot for, never how wide the pool is. *)
module type POOLS = sig
  type 'a io
  type t

  val use : t -> (unit -> 'a io) -> 'a io
end

module Over (Io : Io.S) (Pools : POOLS with type 'a io := 'a Io.t) : sig
  (** What the store needs of the domain below it. Presence rather than an
      entry: the only thing asked of a store is whether it holds a key, and
      answering less keeps the backend's vocabulary out of this one. *)
  module type DEPS = sig
    val put : key:Stored_key.t -> data:Bigstring.t -> unit -> unit Io.t

    (** Where a chunk key is written. *)
    val backend_key : string -> Stored_key.t

    (** Whether the store holds it, wherever a collection may have left it. *)
    val present : string -> bool Io.t

    val fetch_body : string -> Bigstring.t Io.t

    (** Whether the store filed this key as not holding what its name says, and
        how to stop holding it against the rest of the session once a write has
        cleared it — a write is what clears a marker, the store having
        re-verified the object as it took it. *)
    val corrupt : string -> bool Io.t

    val cleared : string -> unit

    (** Bytes in flight, and reads in flight. Held here rather than per caller
        so one device and one memory budget bound every route in. *)
    val slots : Pools.t

    val downloads : Pools.t
    val max_known : unit -> int
  end

  module Make (_ : DEPS) : sig
    (** The chunk's name, and whether this call is what sent it — a deduplicated
        chunk is as done as a written one and cost no transfer, which is why the
        two are told apart rather than summed. *)
    val store : unit Io.t Chunk_source.t -> (string * bool) Io.t

    val fetch : string -> Bigstring.t Io.t

    (** Keys this session has spared itself a round trip on. *)
    val known_count : unit -> int
  end
end
