(** The S3 XML dialect of bulk deletes (backends/s3 §4.3), which the GCS XML API
    speaks too. *)

val escape : string -> string
val unescape : string -> string

(** Whether XML 1.0 can carry [s]: no control character but tab, newline and
    carriage return. *)
val safe : string -> bool

(** A quiet [<Delete>] request for [keys]. *)
val delete_body : string list -> string

(** The [<Error>] elements of a bulk-delete answer, as (code, key). *)
val delete_errors : string -> (string * string) list
