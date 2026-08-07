(** What a backend is: the operations every store provides, the vocabulary for
    reporting a failure, and the registry a driver adds itself to.

    Nothing here talks to a store. The drivers under [backends/drivers] each
    register a factory from their own initialiser, and the composites under
    [backends/wrappers] present {!S} over several of them. *)

type file_entry = { key : string; size : int; last_modified : float }

module type S = sig
  val put : key:string -> data:string -> unit -> unit Lwt.t
  val get : key:string -> unit -> string Lwt.t

  (** [None] when the key does not exist; other failures raise. Saves the HEAD
      round trip of [head_opt] + [get] when the body is wanted. *)
  val get_opt : key:string -> unit -> string option Lwt.t

  val head_opt : key:string -> unit -> file_entry option Lwt.t
  val delete : key:string -> unit -> unit Lwt.t
  val delete_multi : string list -> unit Lwt.t
  val copy : src_key:string -> dst_key:string -> unit -> unit Lwt.t

  val list_prefix :
    ?max_keys:int -> prefix:string -> unit -> file_entry list Lwt.t

  (** The share base URL if this backend serves shares for [prefix]'s domain,
      else [None]. s3 answers with its configured [shareUrl]; http-proxy asks
      the frontend; others answer [None]. [prefix] identifies the domain, for
      backends that front several. *)
  val share_url : prefix:string -> unit -> string option Lwt.t

  (** The chunk size this backend recommends for new files in [prefix]'s domain,
      or [None] with no opinion — which is every store that only holds bytes. An
      http-proxy answers with the serving domain's own setting, so a client
      behind one inherits it instead of the value being mirrored in two configs.
      Consulted only when the client's own config is silent. *)
  val default_chunk_size : prefix:string -> unit -> int option Lwt.t

  (** How many object reads or writes this backend can usefully serve at once,
      or [None] with no opinion — every store whose limit is the network rather
      than a measurable device.

      Asked by frontends taking work from many clients, so they hold requests
      instead of handing them all to storage. A local store answers from the
      device under it; an http-proxy asks its peer, so a client inherits the
      real limit rather than guessing at hardware it cannot see. *)
  val max_concurrency : prefix:string -> unit -> int option Lwt.t
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

(** What to put in a log line. {!Printexc.to_string} would repeat the operation
    name the caller has already printed. *)
val reason : exn -> string

(** The one retry loop. A backend decides only what [Transient] means for it;
    the backoff, the cap and the log line are shared, so two stores cannot drift
    into retrying differently. {!Cancelled} is never retried. *)
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

(** {1 Introspection}

    A domain's backends individually. The composites present one {!S} and keep
    their members' names to themselves, so whoever builds a domain's backends
    declares them here rather than each composite growing its own introspection
    interface. Only diagnosis reads this; nothing routes on it. *)

type member = {
  name : string;
  role : string;  (** main | replica | backfill | readOnly *)
  backend_type : string;  (** local | s3 | gcs | http-proxy *)
  config : (string * string) list;
      (** What this store points at — a bucket, a URL, a path — with secret
          fields masked: a report gets pasted into bug threads. *)
  backend : (module S);  (** The leaf store, so a reader can probe it. *)
  pending : (unit -> int) option;
      (** Replica and backfill: jobs this target still owes, kept on disk. *)
  in_flight : (unit -> int) option;
      (** Replica and backfill: chunk forwards in flight. *)
  degraded : (unit -> bool) option;
      (** Replica and backfill: writes were dropped and [tsync resync-remote] is
          needed — unlike a target merely being behind, patience will not fix
          this. *)
  local_path : string option;
      (** Where a [local] store keeps its files, so a report can say how much
          room is left. Absent for stores whose capacity is not ours to know. *)
}

val report_members : domain:string -> member list -> unit
val members : domain:string -> member list

(** {1 Registry}

    A driver registers a factory from its own initialiser and is kept in the
    link by [-linkall], so adding one is a matter of linking its library. *)

type factory = (string -> string option) -> (module S)
type field_type = [ `String | `Bool ]

(** One configuration field, so [tsync configure] can prompt for a backend's
    settings without knowing the backend. *)
type field_spec = {
  name : string;
  label : string;
  typ : field_type;
  default : string option;
      (** [None] is required; [Some ""] optional, omitted from JSON when blank;
          [Some s] optional with default [s]. *)
  secret : bool;
}

val register : spec:field_spec list -> string -> factory -> unit
val spec_for : string -> field_spec list option

(** Every registered type name, for a UI offering a choice. What is available
    depends on how the binary was linked, since s3 is optional. *)
val types : unit -> string list

(** Raises [Failure] for a type name nothing registered. *)
val make :
  backend_type:string -> get_field:(string -> string option) -> (module S)
