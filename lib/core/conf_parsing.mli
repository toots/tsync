type backend_config = {
  backend_type : string;
  name : string;
      (** required; selects backends, e.g. [resync-remote --source] *)
  fields : (string * string) list;
  main : bool;  (** explicitly marked as the primary (read) backend *)
}

type domain = {
  name : string;
  prefix : string;
  backends : backend_config list;
  symlink_policy : [ `Keep | `Follow | `Skip ];
  versioning : bool;
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
