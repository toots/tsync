module type POOL = sig
  type 'a io
  type t

  (** The pooled connection was unusable and the request never left. *)
  exception Redial

  val create : keep:int64 -> parallel:int -> unit -> t

  (** [alive] is called as the answer arrives, piece by piece. *)
  val call :
    t ->
    alive:(unit -> unit) ->
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
      forever, and a retry loop only ever sees failures, never stalls. It is how
      long an answer may go without a byte of it arriving, so a large body on a
      slow link is not a stall; a request body being sent is not heard, and has
      the whole of it to cross in. Callers choose it, since what counts as
      stalled differs by peer.

      [health] is the one peer this client talks to, told how each request went.
  *)
  val create :
    name:string ->
    timeout:float ->
    classify:(exn -> Retry.kind) ->
    health:Health.t ->
    unit ->
    t

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
