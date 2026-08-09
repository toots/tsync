(** What a backend is for. Required per backend; there is no default.

    - [`Main] — a writable source of truth. Reads prefer the first one in config
      order; a write fans out over every main and returns once they have it.
    - [`Replica] — a complete second copy: it receives every write, journal and
      cursor included, and serves reads when no main is reachable.
    - [`Backfill] — the same copy, never read from, and starting empty: it
      covers what is written from then on. Content only: no journal, no cursor,
      since nothing reads those from a store nothing reads.
    - [`Read_only] — an authoritative store consulted when the source of truth
      misses or is unreachable, and never written.

    A replica and a backfill target are one thing, {!Deferred}, differing only
    in whether reads reach it.

    Both are filled behind the write rather than in it, so a failover read is
    behind by whatever the target still owes — work kept on disk and resumed
    after a restart. *)
type role = [ `Main | `Replica | `Backfill | `Read_only ]

(** Every role, in the order worth presenting to a user. *)
val roles : role list

(** The spelling used in the config JSON, e.g. [`Read_only] is ["readOnly"]. *)
val role_name : role -> string

val role_of_string : string -> role option

type backend_config = {
  backend_type : string;
  name : string;
      (** Required; selects backends, e.g. [resync-remote --source]. *)
  fields : (string * string) list;
  role : role;
      (** Required: ["main"], ["replica"], ["backfill"] or ["readOnly"]. *)
}

type frontend_config = {
  frontend_type : string;
  options : (string * string) list;
      (** Per-frontend options, e.g. http-proxy's [port] and [secret]; empty for
          the bare-string form. Non-string JSON values arrive stringified. *)
}

type domain = {
  name : string;
  backends : backend_config list;
  frontends : frontend_config list;
      (** Required, non-empty; each entry is a type name ["fuse"] or an object
          [{"type": "fuse", ...options}]. *)
  symlink_policy : [ `Keep | `Follow | `Skip ];
  versioning : bool;
  read_only : bool;
      (** The domain's [readOnly] flag, forced on when every backend is
          [`Read_only]: such a domain cannot accept a write, so the mount says
          so up front. *)
  chunk_size : int option;
      (** Chunk size (bytes) for newly uploaded files. [None] when the config
          does not say; resolving that is {!Conf.S.chunk_size}'s business. *)
  cache_chunk_size : int option;
      (** Cache chunk size (bytes): consecutive stored chunks are grouped into
          local cache files of about this size. [None] when the config does not
          say. *)
  max_cache : int option;
      (** Soft cap (bytes) on local cache usage; [None] is unbounded. *)
}

type t = {
  name : string;
  tls : string option;  (** conduit TLS backend: "native" | "openssl" *)
  max_uploads : int;
      (** Max concurrent upload operations (default 4): how many files the
          upload workers process at once. *)
  max_chunk_buffers : int;
      (** Max chunk bodies held in memory at once, across every upload (default:
          [max_uploads]); a host that cannot afford [max_uploads] whole chunks
          lowers this rather than the chunk size.

          Budget about twice this times the domain's chunk size, the backend
          holding its own copy of each body it sends, and per upload path rather
          than per process. *)
  max_downloads : int;  (** max concurrent file downloads (default 8) *)
  domains : domain list;
}

val default_max_uploads : int
val default_max_downloads : int

(** Parse a human-friendly size into bytes: [512K], [8M], [1G], [1048576], and
    the decimal spelling {!Metrics.human_bytes} prints ([8.0 MB], [1.5 GB]),
    with optional [B]/[iB] and an optional space. Binary multiples (1K = 1024).
    [None] if unparseable.

    There is no matching [format_size]: a size shown to a person is spelled by
    {!Metrics.human_bytes}, and a size stored in the config or on the wire is a
    plain integer of bytes. *)
val parse_size : string -> int option

(** Load configuration from [path], or from the JSON string in
    [$TSYNC_CONFIG_JSON] if set (overrides [path]). *)
val load : string -> t

(** {!load}'s parse and validation, over a JSON value already in hand. Raises
    [Failure] with the same message {!load} would.

    Exported so [tsync configure] validates what it is about to write with the
    reader's own rules rather than a second set of its own. *)
val of_json : Yojson.Basic.t -> t

(** Return the domain matching [domain], or the unique domain when omitted.
    Raises [Failure] when multiple domains are configured and none is named. *)
val pick_domain : ?domain:string -> t -> domain

(** [bs] in read preference — mains, then replicas, then read-only stores, then
    backfill targets — each group keeping its config order. Reads use the head,
    so config order selects the read primary. *)
val order_backends : backend_config list -> backend_config list

val domain_prefix : domain -> string
val chunk_prefix : domain -> string
val versions_prefix : domain -> string
val journal_prefix : domain -> string
val cursor_key : domain -> string
val shares_prefix : domain -> string
