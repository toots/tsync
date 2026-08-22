(* One pooled HTTP client for the stores that speak HTTP.

   Pooled per endpoint rather than per request: a catch-up run makes tens of
   thousands of requests, and a handshake each costs three round trips where one
   would do, caps throughput at a few dozen a second, and leaves thousands of
   sockets in TIME_WAIT. *)

open Lwt.Syntax

(* Cohttp already applies both of these over its Unix net; deriving them again
   here would be a second spelling of the same two lines. *)
module Connection = Cohttp_lwt_unix.Connection
module Cache = Cohttp_lwt_unix.Connection_cache

(* Long enough to span the gaps between the bursts a sync or a demand-paged read
   arrives in, short enough not to hold sockets open indefinitely. *)
let keep_idle_ns = 60_000_000_000L

(* Sockets to one endpoint, which is not what any {!Lwt_bounded} pool stands
   for — those bound bodies in memory and round trips in flight. The caller's
   own parallelism is what bounds work; this only has to be wide enough not to
   become the narrower limit. *)
let max_parallel = 32

type t = { name : string; timeout : float; mutable cache : Cache.t }

let new_cache () = Cache.create ~keep:keep_idle_ns ~parallel:max_parallel ()
let create ~name ~timeout () = { name; timeout; cache = new_cache () }

(* 5xx and 429 clear on their own; every other 4xx is the store's answer. *)
let is_transient_code c = c >= 500 || c = 429

let backend_error op code body =
  Backend.failed
    ~kind:
      (if is_transient_code code then Backend.Transient else Backend.Permanent)
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

(* [headers] is a thunk because a caller may have to reach the network to build
   them — minting a bearer token — and that belongs inside the deadline below
   rather than before it.

   [Connection.Retry] means the pooled connection was unusable and the request
   never left, and one torn down by the timeout stays in the cache's table as
   permanently failed, so only a new cache redials. It is replaced once per
   generation, so requests that raced into the same dead pool share the one
   redial. *)
let call t ~headers ~meth ?(body = Bigstring.empty) uri =
  let attempt cache =
    Lwt_unix.with_timeout t.timeout (fun () ->
        let* headers = headers () in
        let* resp, rbody =
          Cache.call cache
            ~headers
              (* [`Passthrough]: sent out of the chunk's own bytes rather than a
               copy, which is what a bigstring body is for. The retry below only
               reads them again. *)
            ~body:
              (Cohttp_lwt.Body.of_bigstring (`Passthrough (body)))
            meth uri
        in
        let+ rbody = Cohttp_lwt.Body.to_bigstring rbody in
        (resp, rbody))
  in
  let used = t.cache in
  Lwt.catch
    (fun () -> attempt used)
    (function
      | Connection.Retry ->
          if t.cache == used then t.cache <- new_cache ();
          attempt t.cache
      | exn -> Lwt.fail exn)

(* Raises on a transient status so the shared loop retries it; every other
   response comes back for the verb to interpret, 404 included. *)
let call_retry t ~headers ~meth ?body op uri =
  Backend.with_retry ~name:t.name ~op (fun () ->
      let* resp, rbody = call t ~headers ~meth ?body uri in
      if is_transient_code (code resp) then
        Lwt.fail
          (backend_error op (code resp) (excerpt (Bigstring.to_string rbody)))
      else Lwt.return (resp, rbody))

(* Only an object's own bytes are worth keeping off the heap; the JSON and XML
   verbs carry a body small enough to read as a string, and one they have to
   parse anyway. *)
let call_text t ~headers ~meth ?body op uri =
  let+ resp, rbody = call_retry t ~headers ~meth ?body op uri in
  (resp, Bigstring.to_string rbody)
