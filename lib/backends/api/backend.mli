(** What a backend is: the operations every store provides, the vocabulary for
    reporting a failure, and the registry a driver adds itself to.

    Nothing here talks to a store. The drivers under [backends/drivers] each
    register a factory from their own initialiser, and [backends/domain_store]
    presents {!S} over a domain's several. *)

type file_entry = { key : string; size : int; last_modified : float }

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
  gc : bool;
      (** Whether this store can collect its own unreferenced chunks, which
          takes renaming a directory and renaming within it — see {!Chunk_space}
          — that a filesystem has and an object store does not. Nothing beyond
          [rename] is asked of it: a store with no hard links to give collects
          the same way.

          Asked of a domain's main directly rather than of the composite: it
          describes one store's machinery, not the domain's. *)
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
    slowest participant is not a limit; any wins for {!caps.gc}; every one must
    agree for {!caps.verified}, one unchecked store being enough to make the
    domain's clean bill of health worth nothing. Defined once so two composites
    cannot drift into merging differently. *)
val merge_caps : caps list -> caps

module type S = sig
  val put : key:string -> data:string -> unit -> unit Lwt.t
  val get : key:string -> unit -> string Lwt.t

  (** [None] when the key does not exist; other failures raise. Saves the HEAD
      round trip of [head_opt] + [get] when the body is wanted. *)
  val get_opt : key:string -> unit -> string option Lwt.t

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
  val put_if_absent : key:string -> data:string -> unit -> string Lwt.t

  val head_opt : key:string -> unit -> file_entry option Lwt.t
  val delete : key:string -> unit -> unit Lwt.t

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
  val delete_multi : string list -> unit Lwt.t

  val copy : src_key:string -> dst_key:string -> unit -> unit Lwt.t

  val list_prefix :
    ?max_keys:int -> prefix:string -> unit -> file_entry list Lwt.t

  (** Ask the store to check every chunk it holds against its own name and file
      what fails under {!Chunk_layout.corrupted_prefix}, answering how many
      units of work were queued rather than what they found.

      A store with nothing on its side to run one — a filesystem has no event
      source, an http-proxy peer owns its own store — answers [`Unsupported] so
      the caller can fail rather than report a check that never happened; a
      filesystem's own sweep is [tsync gc --verify]. *)
  val verify_all :
    chunk_prefix:string -> unit -> [ `Queued of int | `Unsupported ] Lwt.t

  (** What this store can tell a client about [prefix]'s domain. [prefix]
      identifies the domain, for backends that front several. *)
  val capabilities : prefix:string -> unit -> caps Lwt.t
end

(** {1 Failure} *)

exception Backend_error of string
exception Cancelled

(** Its own exception rather than a {!Backend_error} carrying a sentence,
    because callers act on it: a frontend turns it into a read-only error for
    the user, and matching on prose breaks the day the sentence is reworded. *)
exception Not_writable

(** Whether a failure is worth trying again, decided by the store that produced
    it — one vocabulary, rather than each backend having its own notion of
    "transient" and each caller having to recognise it. A 503, a dropped socket
    and a full disk clear on their own; a 403, a bad key and a read-only domain
    do not, and retrying those only delays the report. *)
type kind = Transient | Permanent

exception Failed of { kind : kind; op : string; detail : string }

val failed : kind:kind -> op:string -> string -> exn

(** [Transient] for anything unrecognised: a failure mode nobody classified is
    retried rather than silently abandoning the work. *)
val classify : exn -> kind

val string_of_kind : kind -> string

(** Whether a per-key error code from a bulk delete means the object was already
    gone, which is a success. Here rather than in each driver because s3 and gcs
    answer the same question in the same vocabulary, and a driver that got the
    list wrong on its own would either fail a resumed collection or hide a
    delete that did not happen. *)
val absent_code : string -> bool

(** What to put in a log line. {!Printexc.to_string} would repeat the operation
    name the caller has already printed. *)
val reason : exn -> string

(** How long to wait before attempt [n] (1-based): [base] doubling to [cap].

    One formula, so the several things that wait out a transient failure differ
    only in how patient they are, not in shape. *)
val backoff : base:float -> cap:float -> int -> float

(** The one retry loop for a single request. A backend decides only what
    [Transient] means for it; the curve, the cap and the log line are shared, so
    two stores cannot drift into retrying differently. {!Cancelled} is never
    retried. *)
val with_retry :
  ?max_attempts:int ->
  name:string ->
  op:string ->
  (unit -> 'a Lwt.t) ->
  'a Lwt.t

(** {1 Settling background work} *)

(** A composite finishing work in the background registers here, so a process
    about to exit can let it settle without knowing which composites are in
    play. A one-shot command would otherwise take the pending work with it. *)
val on_drain : (unit -> unit Lwt.t) -> unit

val drain : unit -> unit Lwt.t

(** {1 A domain's stores individually}

    The composite presents one {!S} and keeps its members' names to itself, so
    whoever builds a domain's stores describes them here rather than the
    composite growing an introspection interface.

    Carried on {!Conf.S}, which is where a caller that needs one store rather
    than the domain finds it: a report naming each, a resync copying between
    two, a share link choosing where to point. *)

type member = {
  name : string;
  role : string;  (** main | replica | backfill | readOnly *)
  readable : bool;
      (** Whether reads reach this store. False only for a backfill target, and
          that one bit is also what says a share link must not point into it,
          since such a link could name a file the store will never have. *)
  backend_type : string;  (** local | s3 | gcs | http-proxy *)
  config : (string * string) list;
      (** What this store points at — a bucket, a URL, a path — with secret
          fields masked: a report gets pasted into bug threads. *)
  backend : (module S);  (** The leaf store, so a reader can probe it. *)
  pending : (unit -> int) option;
      (** Deferred targets: jobs this one still owes, kept on disk. *)
  in_flight : (unit -> int) option;
      (** Deferred targets: chunk forwards in flight. *)
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
  ?role:string ->
  ?readable:bool ->
  ?backend_type:string ->
  ?config:(string * string) list ->
  ?local_path:string ->
  ?pending:(unit -> int) ->
  ?in_flight:(unit -> int) ->
  ?degraded:(unit -> bool) ->
  name:string ->
  (module S) ->
  member

(** {1 Registry}

    A driver registers a factory from its own initialiser and is kept in the
    link by [-linkall], so adding one is a matter of linking its library. *)

type factory = (string -> string option) -> (module S)

(** The settings this backend type needs, so [tsync config --edit] can prompt
    for them without knowing the backend. See {!Field_spec}. *)
val register : spec:Field_spec.t list -> string -> factory -> unit

val spec_for : string -> Field_spec.t list option

(** Every registered type name, for a UI offering a choice. What is available
    depends on how the binary was linked, since s3 is optional. *)
val types : unit -> string list

(** Raises [Failure] for a type name nothing registered. *)
val make :
  backend_type:string -> get_field:(string -> string option) -> (module S)
