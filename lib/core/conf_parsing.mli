type backend_config = {
  backend_type : string;
  name : string;
      (** required; selects backends, e.g. [resync-remote --source] *)
  fields : (string * string) list;
  main : bool;  (** explicitly marked as the primary (read) backend *)
  backfill : bool;
      (** an incomplete backend to be lazily filled with served chunks; excluded
          from manifest/listing reads. Mutually exclusive with [read_only] *)
  read_only : bool;
      (** an authoritative store used only as a read fallback, never written
          (excluded from write fan-out). Mutually exclusive with [backfill] *)
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
  chunk_size : int option;
      (** chunk size (bytes) for newly uploaded files. [None] when the config
          does not say; what that resolves to is {!Conf.S.chunk_size}'s business,
          not this layer's *)
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

(** [order_backends bs] returns [bs] with the primary backend first (others keep
    their order). The primary is the first backend marked [main], else the first
    local-file backend, else the first configured. Reads use the head of the
    list; writes fan out to all, so ordering only affects read selection. *)
val order_backends : backend_config list -> backend_config list

val domain_prefix : domain -> string
val chunk_prefix : domain -> string
val versions_prefix : domain -> string
val journal_prefix : domain -> string
val cursor_key : domain -> string
val shares_prefix : domain -> string
