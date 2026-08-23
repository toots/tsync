(** A pooled HTTP client, shared by the drivers that speak HTTP.

    Connections are kept and reused per endpoint. A driver that opens one per
    request pays three round trips where one would do and leaves a socket in
    TIME_WAIT for each, which is what caps a catch-up run at a few dozen
    requests a second however fast the link is.

    What is shared is the pool and the vocabulary for reading a response.
    Authentication is not: a caller builds its own headers, since one mints a
    bearer token and another signs the body. *)

type t

(** [create ~name ~timeout ()] holds a pool of its own. [name] is what a retry
    names in the log; [timeout] is the deadline for one request, including
    building its headers.

    That deadline is a stall detector rather than a latency budget: a pooled
    connection whose peer went away without a FIN leaves its request pending
    forever, and a retry loop only ever sees failures, never stalls. Callers
    choose it, since what counts as stalled differs by store. *)
val create : name:string -> timeout:float -> unit -> t

(** One request through the pool, redialling once if the pooled connection
    turned out to be unusable.

    [headers] is a thunk rather than a value because building them may itself
    reach the network, and that belongs inside the deadline rather than before
    it. *)
val call :
  t ->
  headers:(unit -> Cohttp.Header.t Lwt.t) ->
  meth:Cohttp.Code.meth ->
  ?body:Bigstring.t ->
  Uri.t ->
  (Cohttp.Response.t * Bigstring.t) Lwt.t

(** {!call} under {!Backend.with_retry}, raising on a transient status so the
    shared ladder retries it. Every other response comes back for the verb to
    interpret, 404 included. *)
val call_retry :
  t ->
  headers:(unit -> Cohttp.Header.t Lwt.t) ->
  meth:Cohttp.Code.meth ->
  ?body:Bigstring.t ->
  string ->
  Uri.t ->
  (Cohttp.Response.t * Bigstring.t) Lwt.t

(** {!call_retry} reading the body as a string, for the verbs that answer with
    JSON or a sentence and have to parse it anyway. *)
val call_text :
  t ->
  headers:(unit -> Cohttp.Header.t Lwt.t) ->
  meth:Cohttp.Code.meth ->
  ?body:Bigstring.t ->
  string ->
  Uri.t ->
  (Cohttp.Response.t * string) Lwt.t

val code : Cohttp.Response.t -> int
val is_ok : Cohttp.Response.t -> bool

(** Whether a status clears on its own. One answer, so two drivers cannot drift
    into retrying different things. *)
val is_transient_code : int -> bool

(** A {!Backend.Failed} carrying the status and a bounded excerpt of the body,
    classified by {!is_transient_code}. *)
val backend_error : string -> int -> string -> exn

(** A bounded, single-line rendering of a response body, for a log. A failing
    proxy answers with a whole HTML page and a store with pretty-printed JSON;
    both come back as one line, cut with a trailing ellipsis. *)
val excerpt : string -> string
