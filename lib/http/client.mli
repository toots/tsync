(** An HTTP/1.1 client under the discipline of spec 01 §10: pooled keep-alive
    connections per endpoint, one redial of a pooled connection found dead
    before an answer began, and a stall timeout instead of a latency budget.
    Transport failures and stalls are TRANSIENT/LINK; every status is returned.
*)

type endpoint

(** [url] is [http(s)://host[:port][/base]]; the base path prefixes every
    target. [ca_file] replaces the system trust store. *)
val endpoint : ?ca_file:string -> ?max_connections:int -> string -> endpoint

val base_path : endpoint -> string
val host : endpoint -> string
val url : endpoint -> string

type response = { status : int; headers : Codec.headers; body : string }

(** [headers] is computed inside the stall timeout, per attempt. [progress] is
    called for every piece sent or received. *)
val request :
  ?stall:float ->
  ?headers:(unit -> Codec.headers) ->
  ?body:string ->
  endpoint ->
  meth:string ->
  string ->
  response

(** Collapsed whitespace, at most [HTTP_EXCERPT] characters. *)
val excerpt : string -> string
