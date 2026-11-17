(** An HTTP/1.1 client under the discipline of spec 01 §10: pooled keep-alive
    connections per endpoint, one redial of a pooled connection found dead
    before an answer began, and a stall timeout instead of a latency budget.
    Transport failures and stalls are TRANSIENT/LINK; every status is returned.
*)

type endpoint

(** [url] is [http(s)://host[:port][/base]]; the base path prefixes every
    target. [ca_file] replaces the system trust store. With [spill], a
    successful response body that reaches 256 KiB is written to an unlinked file
    in that directory and answered as its mapping; the directory is made at the
    first one. *)
val endpoint :
  ?ca_file:string -> ?max_connections:int -> ?spill:string -> string -> endpoint

val base_path : endpoint -> string
val host : endpoint -> string

(** The [Host] header: the host, and the port when it is not the scheme's. *)
val authority : endpoint -> string

val url : endpoint -> string

type response = {
  status : int;
  headers : Codec.headers;
  body : Tsync_core.Bigstring.t;
  sent : float;  (** {!Tsync_core.Rt.now} as the request head was written *)
}

(** [headers] is computed inside the stall timeout, per attempt. [pace] is
    called with the bytes left before each slice of the body is written, may
    wait, and returns that slice's length (uplink-governor §4.1); by default the
    whole body goes at once. *)
val request :
  ?stall:float ->
  ?max_body:int ->
  ?headers:(unit -> Codec.headers) ->
  ?pace:(int -> int) ->
  ?body:Tsync_core.Bigstring.t ->
  endpoint ->
  meth:string ->
  string ->
  response

(** Collapsed whitespace, at most [HTTP_EXCERPT] characters. *)
val excerpt : Tsync_core.Bigstring.t -> string
