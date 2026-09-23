(** What a backend is: the operations every store provides, the vocabulary for
    reporting a failure, and the registry a driver adds itself to.

    Nothing here talks to a store. The drivers under [backends/drivers] each
    register a factory from their own initialiser, and [backends/domain_store]
    presents {!S} over a domain's several. *)

include module type of struct
  include Backend_intf
end

module Watch_token = Watch_token

(** What a store with nothing native waits in {!S.watch} before letting a caller
    re-read. A cursor-like object is one name, and a store caps writes to a
    single name at about one a second, so looking faster than a writer can
    publish only spends requests. A store that can do better ignores this. *)
val default_watch_interval : float

val no_caps : caps

(** One store's answer out of several. First opinion wins for the preferences;
    the lowest wins for {!caps.max_concurrency}, since a limit that ignores the
    slowest participant is not a limit; every one must agree for
    {!caps.verified}, one unchecked store being enough to make the domain's
    clean bill of health worth nothing. Defined once so two composites cannot
    drift into merging differently. *)
val merge_caps : caps list -> caps

(** Folders one {!S.list_many} request may name, and the bytes of bodies one
    answer is packed to, on both ends of the wire. *)
val max_batch_folders : int

val max_batch_bytes : int

(** One store's own share of what {!Metrics} counts for the whole process. A
    report summing its members would get the process figure back; what it cannot
    get back is which link the bytes crossed, which is the question a domain
    with a fast main and a slow replica actually raises. *)
type traffic = Metrics.traffic = {
  uploaded : Metrics.counter;
  downloaded : Metrics.counter;
}

val new_traffic : unit -> traffic

(** What a store is for. The same spelling the config uses, so a configured role
    reaches a member without being taken apart and put back together. *)
type role = [ `Main | `Replica | `Backfill | `ReadOnly ]

type 'store member = {
  name : string;
  role : role;
  readable : bool;
      (** Whether reads reach this store. False only for a backfill target, and
          that one bit is also what says a share link must not point into it,
          since such a link could name a file the store will never have. *)
  backend_type : string;  (** local | s3 | gcs | http-proxy *)
  config : (string * string) list;
      (** What this store points at — a bucket, a URL, a path — with secret
          fields masked: a report gets pasted into bug threads. *)
  backend : 'store;  (** The leaf store, so a reader can probe it. *)
  pending : (unit -> int) option;
      (** Deferred targets: jobs this one still owes, kept on disk. *)
  in_flight : (unit -> int) option;
      (** Deferred targets: chunk forwards in flight. *)
  traffic : traffic option;
      (** What crossed the link to this store. [None] where there is no link to
          cross — a [local] store — rather than a pair of zeros, which would
          read as a store that is idle rather than one that is a filesystem. *)
  degraded : (unit -> bool) option;
      (** Deferred targets: writes were dropped and [tsync mirror] is needed —
          unlike a target merely being behind, patience will not fix this. *)
  local_path : string option;
      (** Where a [local] store keeps its files, so a report can say how much
          room is left. Absent for stores whose capacity is not ours to know. *)
  link : string option;
      (** The uplink this store is written over, as configured. Absent for a
          [local] store, which is written over none. *)
}

(** The defaults describe a store with nothing special about it: a writable
    main, reads reach it, no deferred target behind it and nothing to report
    beyond its name. That is what a domain with one configured store has. *)
val member :
  ?role:role ->
  ?readable:bool ->
  ?backend_type:string ->
  ?config:(string * string) list ->
  ?local_path:string ->
  ?pending:(unit -> int) ->
  ?in_flight:(unit -> int) ->
  ?degraded:(unit -> bool) ->
  ?traffic:traffic ->
  ?link:string ->
  name:string ->
  'store ->
  'store member

(** The members by role, decided here so a collector, a copy and the composite
    agree on which is which: the mains take every write and serve reads first,
    the deferred ones are the copies filled behind a write. *)
val main : 'store member list -> 'store member option

val deferred : 'store member list -> 'store member list

(** What crossed a store's link and what it is still owed, as the [traffic] and
    [deferred] fields every report spells them in: the daemon's per-store rows
    and a job's alike. Empty for a store that is a tree here. *)
val link_json : 'store member -> (string * Yojson.Safe.t) list

val named : string -> 'store member list -> 'store member option

(** The one member of that name. Raises [Failure] naming the members there are
    when none has it, or saying so when several do. *)
val named_exn : string -> 'store member list -> 'store member

(** {1 Failure} *)

(** A store's considered answer that the object is not there or not as recorded,
    as opposed to the link failing. Always {!Retry.Permanent}. *)
exception Backend_error of string

(** Its own exception rather than a {!Backend_error} carrying a sentence,
    because callers act on it: a frontend turns it into a read-only error for
    the user, and matching on prose breaks the day the sentence is reworded. *)
exception Not_writable

(** A range answer held against what was asked for: [body], or a failure where
    the store sent more than [length] bytes, which is what a store that ignored
    the range does. Written once because three drivers ask it and a driver that
    skipped it would look exactly like one that works — the caller is satisfied
    either way, having been handed the bytes it wanted inside a body it paid for
    in full. *)
val checked_range :
  op:string -> key:string -> length:int -> Bigstring.t -> Bigstring.t

(** Whether a per-key error code from a bulk delete means the object was already
    gone, which is a success. Here rather than in each driver because s3 and gcs
    answer the same question in the same vocabulary, and a driver that got the
    list wrong on its own would either fail a resumed collection or hide a
    delete that did not happen. *)
val absent_code : string -> bool

(** {!Retry.classify} plus the two exceptions a store raises for itself. This is
    the classifier every caller of backend work wants, including one running it
    from a queue. *)
val classify : exn -> Retry.kind

(** The registries here are one per process — the drivers that register
    themselves, the hooks a composite settles through, and the pool the batched
    reads come out of — so this is applied once, in the layer that names a
    scheduler. *)
module Make (Io : Io.S) (Bounded : Bounded.S with type 'a io := 'a Io.t) : sig
  module type Store = S with type 'a io := 'a Io.t

  (** [B]'s {!S.get_many} resolved: its own where it declared one, and [get_opt]
      fanned out where it did not. Callers go through this and never see the
      option, so the fallback is written once and no driver picks its own width.

      Requests are packed to a key count and a byte budget, and asked for one at
      a time, so what a call holds is one request's bodies rather than the whole
      listing's. [slots] is the budget the reads come out of, and a caller that
      has one — a domain's download bound, a resync's [--parallelism] — should
      pass it rather than leave this to a default that cannot see the process.
  *)
  module Batched (B : Store) : sig
    val get_many :
      ?slots:Bounded.t ->
      entries:file_entry list ->
      unit ->
      (Stored_key.t * Bigstring.t option) list Io.t
  end

  (** {1 Settling background work} *)

  (** A composite finishing work in the background registers here, so a process
      about to exit can let it settle without knowing which composites are in
      play. A one-shot command would otherwise take the pending work with it. *)
  val on_drain : (unit -> unit Io.t) -> unit

  val drain : unit -> unit Io.t

  (** {1 A domain's stores individually}

      The composite presents one {!S} and keeps its members' names to itself, so
      whoever builds a domain's stores describes them here rather than the
      composite growing an introspection interface.

      Carried on {!Conf.S}, which is where a caller that needs one store rather
      than the domain finds it: a report naming each, a resync copying between
      two, a share link choosing where to point. *)

  (** {1 Registry}

      A driver registers a factory from its own initialiser and is kept in the
      link by [-linkall], so adding one is a matter of linking its library. *)

  type factory = (string -> string option) -> (module Store)

  (** The settings this backend type needs, so [tsync config --edit] can prompt
      for them without knowing the backend. See {!Field_spec}. *)
  val register : spec:Field_spec.t list -> string -> factory -> unit

  val spec_for : string -> Field_spec.t list option

  (** Every registered type name, for a UI offering a choice. What is available
      depends on how the binary was linked, since s3 is optional. *)
  val types : unit -> string list

  (** Raises [Failure] for a type name nothing registered.

      [traffic] is the store's own counter pair, which the returned module adds
      to alongside the process-wide ones. Omitted, a counted store still counts
      — into a pair nobody holds — so a caller wanting the figure passes one and
      keeps it on the store's {!member}.

      [admission] is the gate each body sent goes through, asked before and told
      after; omitted, a body is sent as it was before there were gates. A local
      store is neither counted nor gated: it has no link. *)
  val make :
    ?traffic:traffic ->
    ?admission:unit Io.t Uplink.admission ->
    backend_type:string ->
    get_field:(string -> string option) ->
    unit ->
    (module Store)
end
