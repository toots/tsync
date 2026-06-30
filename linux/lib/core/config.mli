type domain = { name : string }

type t = {
  bucket : string;
  prefix : string;
  aws_region : string;
  versioning : bool;
  access_key_id : string;
  secret_access_key : string;
  domains : domain list;
}

(** Load configuration from [$XDG_CONFIG_HOME/tsync/config.json], or from the
    JSON string in [$TSYNC_CONFIG_JSON] if set. AWS credentials are read from a
    sibling [credentials.json] when present (macOS compatibility). *)
val load : unit -> t

(** Write [cfg] back to the config file, creating the directory if needed. *)
val save : t -> unit

(** [domain_prefix cfg domain_name] returns the S3 key prefix for all objects
    belonging to [domain_name]: ["<prefix>/<domain_name>/"]. *)
val domain_prefix : t -> string -> string

(** Returns the S3 key prefix under which shared chunk objects are stored:
    ["<prefix>/.chunks/"]. *)
val chunk_prefix : t -> string

(** [trash_prefix cfg domain_name] returns the S3 key prefix for soft-deleted
    files (versioning trash): ["<prefix>/.trash/<domain_name>/"]. *)
val trash_prefix : t -> string -> string

(** [journal_prefix cfg domain_name] returns the S3 key prefix for WAL journal
    entries: ["<prefix>/.journal/<domain_name>/"]. *)
val journal_prefix : t -> string -> string

(** [version_key cfg domain_name] returns the S3 key that holds the latest
    committed journal entry key for [domain_name]:
    ["<prefix>/.version/<domain_name>"]. *)
val version_key : t -> string -> string
