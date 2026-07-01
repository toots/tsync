type t = {
  bucket : string;
  prefix : string;
  aws_region : string;
  versioning : bool;
  access_key_id : string;
  secret_access_key : string;
  domain_name : string;
}

(** Load configuration from [path], or from the JSON string in
    [$TSYNC_CONFIG_JSON] if set (overrides [path]). *)
val load : string -> t

val domain_prefix : t -> string -> string
val chunk_prefix : t -> string
val trash_prefix : t -> string -> string
val journal_prefix : t -> string -> string
val version_key : t -> string -> string
