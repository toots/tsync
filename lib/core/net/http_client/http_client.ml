(* One pooled HTTP client for the stores that speak HTTP.

   Pooled per endpoint rather than per request: a catch-up run makes tens of
   thousands of requests, and a handshake each costs three round trips where one
   would do, caps throughput at a few dozen a second, and leaves thousands of
   sockets in TIME_WAIT. *)

(* 5xx and 429 clear on their own; every other 4xx is the store's answer. *)
let is_transient_code c = c >= 500 || c = 429

let failed op code body =
  Retry.failed
    ~kind:(if is_transient_code code then Retry.Transient else Retry.Permanent)
    ~op
    (Printf.sprintf "HTTP %d: %s" code body)

let code resp = Cohttp.Code.code_of_status (Cohttp.Response.status resp)
let is_ok resp = code resp >= 200 && code resp < 300
let excerpt_limit = 200

(* Runs of whitespace to one space, so a body laid out over several lines reads
   as one. *)
let flatten s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
        | ' ' | '\n' | '\r' | '\t' ->
            if Buffer.length b > 0 && Buffer.nth b (Buffer.length b - 1) <> ' '
            then Buffer.add_char b ' '
        | c -> Buffer.add_char b c)
    s;
  String.trim (Buffer.contents b)

(* A proxy in front of a store answers failures with a full HTML page, and one
   stalled fetch can put thousands of lines of nginx markup in the log; the
   status carries the meaning, a fragment of body only tells an upstream apart
   from the store's own answer.

   Flattened rather than cut at the first line break, because a store's own
   error is pretty-printed JSON opening on a lone brace: cutting there excerpts
   the punctuation and drops the message. *)
let excerpt body =
  let body = flatten body in
  if body = "" then "(empty)"
  else if String.length body <= excerpt_limit then body
  else String.sub body 0 excerpt_limit ^ " ..."

(** The sockets themselves: a pool per endpoint, and one request through it.

    Bodies cross as bigstrings rather than in whatever an implementation moves
    them in, so the whole of that vocabulary — and the copy a conversion would
    make — stays on this side. *)
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

module Make
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Loop : Retry.LOOP with type 'a io := 'a Io.t)
    (Pool : POOL with type 'a io := 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x

  (* Long enough to span the gaps between the bursts a sync or a demand-paged read
     arrives in, short enough not to hold sockets open indefinitely. *)
  let keep_idle_ns = 60_000_000_000L

  (* Sockets to one endpoint, which is not what any {!Bounded} pool stands
     for — those bound bodies in memory and round trips in flight. The caller's
     own parallelism is what bounds work; this only has to be wide enough not to
     become the narrower limit. *)
  let max_parallel = 32

  type t = {
    name : string;
    timeout : float;
    classify : exn -> Retry.kind;
    mutable cache : Pool.t;
  }

  let new_cache () = Pool.create ~keep:keep_idle_ns ~parallel:max_parallel ()

  let create ~name ~timeout ~classify () =
    { name; timeout; classify; cache = new_cache () }

  (* [headers] is a thunk because a caller may have to reach the network to
     build them — minting a bearer token — and that belongs inside the deadline
     below rather than before it.

     A connection torn down by the timeout stays in the pool's table as
     permanently failed, so only a new pool redials. It is replaced once per
     generation, so requests that raced into the same dead pool share the one
     redial. *)
  let call t ~headers ~meth ?(body = Bigstring.empty) uri =
    let attempt cache =
      Clock.with_timeout t.timeout (fun () ->
          let* headers = headers () in
          Pool.call cache ~headers ~body meth uri)
    in
    let used = t.cache in
    Io.catch
      (fun () -> attempt used)
      (function
        | Pool.Redial ->
            if t.cache == used then t.cache <- new_cache ();
            attempt t.cache
        | exn -> Io.fail exn)

  (* Raises on a transient status so the shared loop retries it; every other
     response comes back for the verb to interpret, 404 included. *)
  let call_retry t ~headers ~meth ?body op uri =
    Loop.with_retry ~classify:t.classify ~name:t.name ~op (fun () ->
        let* resp, rbody = call t ~headers ~meth ?body uri in
        if is_transient_code (code resp) then
          Io.fail (failed op (code resp) (excerpt (Bigstring.to_string rbody)))
        else Io.return (resp, rbody))

  (* Only an object's own bytes are worth keeping off the heap; the JSON and XML
     verbs carry a body small enough to read as a string, and one they have to
     parse anyway. *)
  let call_text t ~headers ~meth ?body op uri =
    let+ resp, rbody = call_retry t ~headers ~meth ?body op uri in
    (resp, Bigstring.to_string rbody)
end
