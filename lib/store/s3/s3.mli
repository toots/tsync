(** The [s3] driver (spec backends/s3.md). Registers itself when linked. *)

(**/**)

val uri_encode : ?keep_slash:bool -> string -> string
val canonical_query : (string * string) list -> string
val amz_date : float -> string

type credentials = { access_key : string; secret : string; region : string }

val authorization :
  credentials ->
  time:float ->
  meth:string ->
  path:string ->
  query:string ->
  headers:(string * string) list ->
  payload_hash:string ->
  string
