(** Versioning stores a timestamped copy of a file's manifest under
    [versions_prefix] every time the file is modified, renamed or deleted. Since
    manifests reference shared content-addressed chunks, a version is a cheap
    manifest copy and can be restored without transferring any file content.
    Chunks are collected only when [Expire] removes the last version referencing
    them. *)

(** Prefix holding every version of the file currently at [s3_key], i.e.
    [versions_prefix ^ <relative-path> ^ "/"]. *)
val version_dir :
  s3_key:string -> domain_prefix:string -> versions_prefix:string -> string

(** Backend key for a fresh version of [s3_key]: its [version_dir] suffixed with
    the current time in nanoseconds (fine enough that rapid saves don't
    collide). *)
val version_key :
  s3_key:string -> domain_prefix:string -> versions_prefix:string -> string

(** Split a version object key into its relative path and timestamp suffix, or
    [None] if it is not under [versions_prefix]. *)
val parse : versions_prefix:string -> string -> (string * string) option

(** Copy the live manifest at [key] to a timestamped version key on every
    backend, unless [key] has no live manifest (e.g. first upload). *)
val save :
  backends:(module Backend.S) list ->
  domain_prefix:string ->
  versions_prefix:string ->
  key:string ->
  unit
