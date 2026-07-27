(** What a backend is for. Required per backend; there is no default.

    - [`Main] — a writable source of truth. Reads prefer the first one in config
      order; a write fans out over every main and replica.
    - [`Replica] — a complete second copy: it receives every write, journal and
      cursor included, and serves reads when no main is reachable. Differs from
      a second [`Main] only in read preference, which is the point — it names
      the intent. See {!Fallback_backend}.
    - [`Backfill] — a converging copy, filled lazily from the write side and
      never read from. Content only: no journal, no cursor. See
      {!Backfill_backend}.
    - [`Read_only] — an authoritative store consulted when the source of truth
      misses or is unreachable, and never written. See {!Fallback_backend}. *)
type role = [ `Main | `Replica | `Backfill | `Read_only ]

(** Every role, in the order worth presenting to a user. *)
val roles : role list

(** The spelling used in the config JSON, e.g. [`Read_only] is ["readOnly"]. *)
val role_name : role -> string

val role_of_string : string -> role option

type backend_config = {
  backend_type : string;
  name : string;
      (** required; selects backends, e.g. [resync-remote --source] *)
  fields : (string * string) list;
  role : role;  (** required: ["main"], ["backfill"] or ["readOnly"] *)
}

type frontend_config = {
  frontend_type : string;
  options : (string * string) list;
      (** future per-frontend options; empty for the bare-string form *)
}

type domain = {
  name : string;
  backends : backend_config list;
  frontends : frontend_config list;
      (** required, non-empty; each entry is a type name ["fuse"] or an object
          [{"type": "fuse", ...options}] *)
  symlink_policy : [ `Keep | `Follow | `Skip ];
  versioning : bool;
  read_only : bool;
      (** the domain's [readOnly] flag, forced on when no backend is writable
          (every one is [`Read_only]) — such a domain cannot accept a write, so
          the mount says so up front *)
  chunk_size : int option;
      (** chunk size (bytes) for newly uploaded files. [None] when the config
          does not say; what that resolves to is {!Conf.S.chunk_size}'s
          business, not this layer's *)
  cache_chunk_size : int option;
      (** cache chunk size (bytes): consecutive stored chunks are grouped into
          local cache files of about this size. [None] when the config does not
          say *)
  max_cache : int option;
      (** soft cap (bytes) on local cache usage; [None] = unbounded *)
}

type t = {
  name : string;
  tls : string option;  (** conduit TLS backend: "native" | "openssl" *)
  max_uploads : int;
      (** max concurrent upload operations (default 4): bounds both how many
          files the upload workers process at once and, via the shared chunk
          buffer pool, how many chunk reads/uploads run concurrently across all
          of them combined *)
  max_downloads : int;  (** max concurrent file downloads (default 8) *)
  domains : domain list;
}

val default_max_uploads : int
val default_max_downloads : int

(** Render a byte count as a human-friendly binary size (e.g. [8M], [512K]);
    exact multiples only, else the raw number. *)
val format_size : int -> string

(** Parse a human-friendly size ([512K], [8M], [1G], [1048576], with optional
    [B]/[iB]) into bytes. Binary multiples (1K = 1024). [None] if unparseable.
*)
val parse_size : string -> int option

(** Load configuration from [path], or from the JSON string in
    [$TSYNC_CONFIG_JSON] if set (overrides [path]). *)
val load : string -> t

(** Return the domain matching [domain], or the unique domain when omitted.
    Raises [Failure] when multiple domains are configured and none is named. *)
val pick_domain : ?domain:string -> t -> domain

(** [order_backends bs] returns [bs] in read preference — mains, then replicas,
    then read-only stores, then backfill targets — each group keeping its config
    order. Reads use the head of the list, so config order is what selects the
    read primary. *)
val order_backends : backend_config list -> backend_config list

val domain_prefix : domain -> string
val chunk_prefix : domain -> string
val versions_prefix : domain -> string
val journal_prefix : domain -> string
val cursor_key : domain -> string
val shares_prefix : domain -> string
