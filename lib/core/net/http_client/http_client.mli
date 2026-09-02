(** A pooled HTTP client, shared by whatever speaks HTTP over a link worth
    keeping open.

    Connections are kept and reused per endpoint. A driver that opens one per
    request pays three round trips where one would do and leaves a socket in
    TIME_WAIT for each, which is what caps a catch-up run at a few dozen
    requests a second however fast the link is.

    What is shared is the pool and the vocabulary for reading a response.
    Authentication is not: a caller builds its own headers, since one mints a
    bearer token and another signs the body.

    The sockets are a parameter, so what is here is the pooling policy and the
    reading of a response, and a module that only reads one links neither an
    HTTP implementation nor a scheduler. *)

val code : Cohttp.Response.t -> int
val is_ok : Cohttp.Response.t -> bool

(** Whether a status clears on its own. One answer, so two drivers cannot drift
    into retrying different things. *)
val is_transient_code : int -> bool

(** A {!Retry.Failed} carrying the status and a bounded excerpt of the body,
    classified by {!is_transient_code}. *)
val failed : string -> int -> string -> exn

(** A bounded, single-line rendering of a response body, for a log. A failing
    proxy answers with a whole HTML page and a store with pretty-printed JSON;
    both come back as one line, cut with a trailing ellipsis. *)
val excerpt : string -> string

(** The sockets themselves: a pool per endpoint, and one request through it.

    Bodies cross as bigstrings rather than in whatever an implementation moves
    them in, so the whole of that vocabulary — and the copy a conversion would
    make — stays on that side. *)
module type POOL = sig
  type 'a io
  type t

  (** The pooled connection was unusable and the request never left. *)
  exception Redial

  val create : keep:int64 -> parallel:int -> unit -> t

  val call :
    t ->
    headers:Cohttp.Header.t ->
    body:Bigstring.t ->
    Cohttp.Code.meth ->
    Uri.t ->
    (Cohttp.Response.t * Bigstring.t) io
end

module type S = sig
  type 'a io

  type t

  (** Holds a pool of its own. [name] is what a retry names in the log;
      [classify] decides what {!call_retry} waits out, taken here rather than
      per request so a caller cannot end up passing none.

      [timeout] is a stall detector rather than a latency budget: a pooled
      connection whose peer went away without a FIN leaves its request pending
      forever, and a retry loop only ever sees failures, never stalls. Callers
      choose it, since what counts as stalled differs by peer. *)
  val create :
    name:string -> timeout:float -> classify:(exn -> Retry.kind) -> unit -> t

  (** One request through the pool, redialling once if the pooled connection
      turned out to be unusable.

      [headers] is a thunk rather than a value because building them may itself
      reach the network, and that belongs inside the deadline rather than before
      it. *)
  val call :
    t ->
    headers:(unit -> Cohttp.Header.t io) ->
    meth:Cohttp.Code.meth ->
    ?body:Bigstring.t ->
    Uri.t ->
    (Cohttp.Response.t * Bigstring.t) io

  (** {!call} under the retry loop, raising on a transient status so the shared
      ladder retries it. Every other response comes back for the verb to
      interpret, 404 included. *)
  val call_retry :
    t ->
    headers:(unit -> Cohttp.Header.t io) ->
    meth:Cohttp.Code.meth ->
    ?body:Bigstring.t ->
    string ->
    Uri.t ->
    (Cohttp.Response.t * Bigstring.t) io

  (** {!call_retry} reading the body as a string, for the verbs that answer with
      JSON or a sentence and have to parse it anyway. *)
  val call_text :
    t ->
    headers:(unit -> Cohttp.Header.t io) ->
    meth:Cohttp.Code.meth ->
    ?body:Bigstring.t ->
    string ->
    Uri.t ->
    (Cohttp.Response.t * string) io
end

module Make
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Loop : Retry.LOOP with type 'a io := 'a Io.t)
    (Pool : POOL with type 'a io := 'a Io.t) :
  S with type 'a io := 'a Io.t
