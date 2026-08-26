(** What a backend is: the operations every store provides, the vocabulary for
    reporting a failure, and the registry a driver adds itself to.

    Nothing here talks to a store. The drivers under [backends/drivers] each
    register a factory from their own initialiser, and [backends/domain_store]
    presents {!S} over a domain's several. *)

type file_entry = {
  key : Stored_key.t;
  size : int;
  last_modified : float;
  etag : string option;
      (** What the store calls this object's version, when it has a name for
          one: an S3 or GCS listing carries it, a filesystem has none.

          The only validator worth caching an object's body against. Size and
          [last_modified] are not: S3 reports whole seconds, and a manifest
          rewritten inside one to a body of the same length — same name, same
          chunk count — is invisible in both. *)
}

(** {1 What a store can say about a domain}

    One record rather than a method each: a composite merges them once, and
    adding a capability is a field here instead of an edit to every driver and
    every composite.

    A preference is [None] for a store with no opinion; a capability is a plain
    [bool], having no gap between "no opinion" and "cannot". *)
type caps = {
  share_url : string option;
      (** The share base URL, if this store serves shares for the domain. s3 and
          gcs answer with their configured [shareUrl]; http-proxy asks the
          frontend. *)
  chunk_size : int option;
      (** The chunk size this store recommends for new files. An http-proxy
          answers with the serving domain's own setting, so a client behind one
          inherits it instead of the value being mirrored in two configs.
          Consulted only when the client's own config is silent. *)
  max_concurrency : int option;
      (** How many object reads or writes this store can usefully serve at once,
          so a frontend taking work from many clients holds requests instead of
          handing them all to storage. A local store answers from the device
          under it; an http-proxy asks its peer. *)
  verified : bool;
      (** Whether every chunk this store takes is held against its own name
          ({!Corruption}): a [local] store as it writes unless that was turned
          off, an s3 or gcs store in the function its bucket's object-created
          event triggers.

          Reported rather than merely used, because a store that looked and
          found nothing and a store that never looked both list zero markers. *)
}

val no_caps : caps

(** One store's answer out of several. First opinion wins for the preferences;
    the lowest wins for {!caps.max_concurrency}, since a limit that ignores the
    slowest participant is not a limit; every one must agree for
    {!caps.verified}, one unchecked store being enough to make the domain's
    clean bill of health worth nothing. Defined once so two composites cannot
    drift into merging differently. *)
val merge_caps : caps list -> caps

module type S = sig
  type 'a io

  val put : key:Stored_key.t -> data:Bigstring.t -> unit -> unit io
  val get : key:Stored_key.t -> unit -> Bigstring.t io

  (** [None] when the key does not exist; other failures raise. Saves the HEAD
      round trip of [head_opt] + [get] when the body is wanted. *)
  val get_opt : key:Stored_key.t -> unit -> Bigstring.t option io

  (** Write [data] at [key] only if nothing is there, answering with whatever is
      there afterwards — [data] itself when this call won, the other writer's
      body when it did not.

      For a key that names a claim rather than content, where several clients
      may reach for it at once and exactly one must win: {!put} is
      last-writer-wins, so the loser's work would be stranded with nothing
      saying so.

      A claim is the only thing this is for — content is either
      content-addressed, in which case racing writers agree, or owned by one
      client. *)
  val put_if_absent :
    key:Stored_key.t -> data:Bigstring.t -> unit -> Bigstring.t io

  val head_opt : key:Stored_key.t -> unit -> file_entry option io
  val delete : key:Stored_key.t -> unit -> unit io

  (** Delete every key, or raise. Two things callers depend on and every driver
      owes them:

      - a key that is not there is not a failure. {!Gc} sends every copy the
        same list whether or not it holds each one, and a resumed run repeats a
        batch it may already have deleted.
      - a list longer than whatever the store takes per request is still deleted
        whole; the driver pages.

      Bulk deletes are the awkward case, because a store answers one of these
      with a [200] carrying a per-key failure list. A driver that reads only the
      status reports success over keys that are still there — and nothing walks
      a copy afterwards to notice. See {!absent_code}. *)
  val delete_multi : Stored_key.t list -> unit io

  val copy : src_key:Stored_key.t -> dst_key:Stored_key.t -> unit -> unit io
  val list_prefix : ?max_keys:int -> prefix:string -> unit -> file_entry list io

  (** A native multi-object read, or [None] from a store with none — which is
      every store but http-proxy, S3 having no multi-object GET and the GCS
      batch API carrying metadata only.

      Declared rather than implemented, so a store without one says so and
      {!Batched} supplies the fan-out. A driver spelling its own would be
      choosing a width from inside a driver, which cannot see what else shares
      the process, and four drivers would then have four of them.

      Entries rather than bare keys as {!delete_multi} takes: a read has an
      answer to hold, so whoever packs a request needs the sizes, and a caller
      with a batch to make has just listed them.

      What a store declaring one owes its callers:

      - every key asked for is answered exactly once, in the order asked;
      - an absent key is answered [None], not a failure;
      - a list longer than the store takes per request is still answered whole;
        the driver pages.
      - a per-key failure is raised rather than answered [None]. This is
        {!absent_code}'s lesson for reads: a caller told a key is absent writes
        a mirror missing that file, and nothing walks it afterwards to notice.
  *)
  val get_many :
    (entries:file_entry list ->
    unit ->
    (Stored_key.t * Bigstring.t option) list io)
    option

  (** Ask the store to check every chunk it holds against its own name and file
      what fails under {!Chunk_layout.corrupted_prefix}, answering how many
      units of work were queued rather than what they found.

      A store with nothing on its side to run one — a filesystem has no event
      source, an http-proxy peer owns its own store — answers [`Unsupported] so
      the caller can fail rather than report a check that never happened; a
      filesystem's own sweep is [tsync gc --verify]. *)
  val verify_all :
    chunk_prefix:string -> unit -> [ `Queued of int | `Unsupported ] io

  (** Hand a collection's unreferenced chunks to whatever this store has on its
      side to delete them, rather than deleting them from here. Answers
      [`Queued] having written a request its bucket's own notification delivers
      — the function drops the chunks and derives the markers naming them, so
      {!Gc} sends only the chunk keys.

      [`Unsupported] from a store with no such function, which is every store
      unless its bucket was deployed with one; {!Gc} then falls back to
      {!delete_multi} and nothing about the collection changes. The gap between
      "no opinion" and "cannot" matters more here than for {!verify_all}: a
      store wrongly claiming this would leave keys on a copy for good, since
      nothing walks a copy's own shards afterwards.

      What lets {!Gc} discard the main straight after [`Queued] is that the
      request is durably stored before this returns. Awaited, never detached — a
      request that had not landed yet would put the collection back to deleting
      the evidence before recording the instruction.

      [run] and [name] identify the batch: {!Gc} passes the collection it
      belongs to and the cursor it is about to save, so a re-run of an
      interrupted flush overwrites its own request while a later collection
      cannot overwrite one this collection left behind. *)
  val discard :
    chunk_prefix:string ->
    run:string ->
    name:string ->
    keys:Stored_key.t list ->
    unit ->
    [ `Queued | `Unsupported ] io

  (** What this store can tell a client about [prefix]'s domain. [prefix]
      identifies the domain, for backends that front several. *)
  val capabilities : prefix:string -> unit -> caps io

  (** The directory this store keeps its objects in, where the object for a key
      is the file at that path under it. [None] for a store to be reached only
      through the operations above.

      What it grants is the filesystem: a caller may read, rename and remove
      within the tree. Nothing here says what anyone does with that — a
      collection renames the chunk root aside and renames chunks back
      ({!Collection}), and a report only wants a path to measure. *)
  val local_path : string option
end

(** One store's own share of what {!Metrics} counts for the whole process. A
    report summing its members would get the process figure back; what it cannot
    get back is which link the bytes crossed, which is the question a domain
    with a fast main and a slow replica actually raises. *)
type traffic = { uploaded : Metrics.counter; downloaded : Metrics.counter }

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
  name:string ->
  'store ->
  'store member

(** {1 Failure} *)

(** A store's considered answer that the object is not there or not as recorded,
    as opposed to the link failing. Always {!Retry.Permanent}. *)
exception Backend_error of string

(** Its own exception rather than a {!Backend_error} carrying a sentence,
    because callers act on it: a frontend turns it into a read-only error for
    the user, and matching on prose breaks the day the sentence is reworded. *)
exception Not_writable

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

(** What the batched reads need of a pool. *)
module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val use : t -> (unit -> 'a io) -> 'a io
  val map_with : t -> ('a -> 'b io) -> 'a list -> 'b list io
end

(** The registries here are one per process — the drivers that register
    themselves, the hooks a composite settles through, and the pool the batched
    reads come out of — so this is applied once, in the layer that names a
    scheduler. *)
module Make (Io : Io.S) (Bounded : POOLS with type 'a io := 'a Io.t) : sig
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
      keeps it on the store's {!member}. *)
  val make :
    ?traffic:traffic ->
    backend_type:string ->
    get_field:(string -> string option) ->
    unit ->
    (module Store)
end
