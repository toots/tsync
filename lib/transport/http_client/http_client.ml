(* The pooled HTTP client the plain-HTTP drivers share — the proxy and GCS — so
   that what counts as "this peer is not answering" is decided in one place
   rather than once per driver.

   A peer has two ways to stop answering without ever failing, and neither
   reaches {!Backend.with_retry}, which only ever sees failures, never stalls: a
   host that is simply not there draws no RST and no ICMP, so the dial sits in
   SYN_SENT; and a pooled connection whose peer went away without a FIN leaves
   its request pending forever.

   Two clocks, because the two halves of a request fail differently and want
   opposite deadlines.

   Getting a response at all — dial, send, first header byte — is quick against
   any peer that is answering, so a short bound here is what turns "this host is
   gone" into an error rather than a stall. Streaming the body afterwards is
   real work whose length is the file's, not the network's, so it gets a
   generous one: exceeding that is a stall detector, not a latency budget.

   One budget over both cannot serve both, and it was the body's number that
   won: a black-holed host took the full 300s to be reported, eight times over
   with backoff, which is how one unplugged machine wedged a domain for the
   better part of an hour. *)
let response_timeout = 30.
let body_timeout = 300.

(* Deliberately no deadline on the dial itself. One was tried, wrapping
   [Net.connect_endp]: it fires on time and changes nothing a caller can see,
   because a dial cancelled underneath the connection cache leaves the cache's
   waiter parked until something above it gives up. [response_timeout] is that
   something, and it already covers the dial. *)
module Connection = Cohttp_lwt.Connection.Make (Cohttp_lwt_unix.Net)

module Cache =
  Cohttp_lwt.Connection_cache.Make
    (Connection)
    (struct
      let sleep_ns ns = Lwt_unix.sleep (Int64.to_float ns /. 1e9)
    end)

(* Long enough to span the gaps between the bursts a sync or a demand-paged read
   arrives in, short enough not to hold sockets open indefinitely. *)
let keep_idle_ns = 60_000_000_000L

(* The caller's own parallelism (the resync pool, the download pool) is what
   bounds work; this only has to be wide enough not to become the narrower
   limit. *)
let max_parallel = 32

type t = { mutable cache : Cache.t }

(* [retry:0] because {!Backend.with_retry} above already owns retrying, and does
   it better: with backoff, with a cap, and saying so in the log. The cache's own
   loop is silent, immediate, and multiplies whatever a failed attempt costs. *)
let new_cache () =
  Cache.create ~keep:keep_idle_ns ~parallel:max_parallel ~retry:0 ()

let create () = { cache = new_cache () }

(* Pooled per endpoint rather than per request: a full resync fetches tens of
   thousands of objects, and a handshake each caps throughput at a few dozen a
   second while leaving thousands of sockets in TIME_WAIT.

   [Connection.Retry] means the pooled connection was unusable and the request
   never left, and one torn down by a deadline stays in the cache's table as
   permanently failed, so only a new cache redials. It is replaced once per
   generation, so requests that raced into the same dead pool share the one
   redial. *)
let call t ~headers ?(body = "") meth uri =
  let attempt cache =
    Lwt.bind
      (Lwt_unix.with_timeout response_timeout (fun () ->
           Cache.call cache ~headers ~body:(Cohttp_lwt.Body.of_string body) meth
             uri)) (fun (resp, rbody) ->
        Lwt.map
          (fun s -> (resp, s))
          (Lwt_unix.with_timeout body_timeout (fun () ->
               Cohttp_lwt.Body.to_string rbody)))
  in
  let used = t.cache in
  Lwt.catch
    (fun () -> attempt used)
    (function
      | Connection.Retry ->
          if t.cache == used then t.cache <- new_cache ();
          attempt t.cache
      | exn -> Lwt.fail exn)
