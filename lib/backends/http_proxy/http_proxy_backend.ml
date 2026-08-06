open Lwt.Syntax

exception Cancelled = Backend.Cancelled

(* Pooled per endpoint rather than per request. A full resync fetches one object
   per manifest — tens of thousands — and a one-shot client pays DNS, TCP and TLS
   handshakes for each, capping throughput at a few dozen objects a second and
   leaving thousands of sockets in TIME_WAIT. *)
module Connection = Cohttp_lwt.Connection.Make (Cohttp_lwt_unix.Net)

module Cache =
  Cohttp_lwt.Connection_cache.Make
    (Connection)
    (struct
      let sleep_ns ns = Lwt_unix.sleep (Int64.to_float ns /. 1e9)
    end)

(* Long enough to span the gaps between the bursts a sync or a demand-paged read
   arrives in, short enough not to hold proxy sockets open indefinitely. *)
let keep_idle_ns = 60_000_000_000L

(* The caller's own parallelism (the resync pool, the download pool) is what
   bounds work; this only has to be wide enough not to become the narrower
   limit. *)
let max_parallel = 32

type t = {
  base_uri : Uri.t;
  secret : string;
  cache : Cache.t;
  mutable share_url_cache : string option Lwt.t option;
  mutable chunk_size_cache : int option Lwt.t option;
  mutable max_concurrency_cache : int option Lwt.t option;
}

let max_attempts = 8

(* The connection cache has no deadline of its own: a pooled connection whose
   peer went away without a FIN leaves its request pending forever, and
   [call_retry] only ever sees failures, never stalls. Generous enough for a
   chunk over a slow link — it is a stall detector, not a latency budget. *)
let request_timeout = 300.

let backend_error op code body =
  Backend.Backend_error
    (Printf.sprintf "http-proxy %s: HTTP %d: %s" op code body)

(* Signs method + request-target + body with the shared secret. TLS is conduit's,
   per the global [Tls_conf]. *)
let call t ~meth ?(body = "") uri =
  let resource = Uri.path_and_query uri in
  let headers =
    Cohttp.Header.of_list
      (Http_proxy.Auth.request_headers ~secret:t.secret
         ~meth:(Cohttp.Code.string_of_method meth)
         ~path:resource ~body)
  in
  Lwt_unix.with_timeout request_timeout (fun () ->
      let* resp, rbody =
        Cache.call t.cache ~headers
          ~body:(Cohttp_lwt.Body.of_string body)
          meth uri
      in
      let+ s = Cohttp_lwt.Body.to_string rbody in
      (resp, s))

(* Connection failures and 5xx are transient; [Cancelled] never retries. Every
   proxied operation is idempotent, so retrying is safe. *)
let code resp = Cohttp.Code.code_of_status (Cohttp.Response.status resp)
let is_ok resp = code resp >= 200 && code resp < 300

(* A proxy in front of us answers failures with a full HTML page, and one stalled
   fetch can put thousands of lines of nginx markup in the log. The status carries
   the meaning; one line of body is enough to tell an upstream apart from our own
   answer. *)
let excerpt body =
  let body = String.trim body in
  match String.index_opt body '\n' with
    | _ when String.length body = 0 -> "(empty)"
    | Some i when i < 200 -> String.sub body 0 i ^ " ..."
    | _ when String.length body > 200 -> String.sub body 0 200 ^ " ..."
    | _ -> body

let call_retry t ~meth ?body op uri =
  let rec go attempt =
    let* outcome =
      Lwt.catch
        (fun () ->
          let+ r = call t ~meth ?body uri in
          `Ret r)
        (fun exn -> Lwt.return (`Raised exn))
    in
    let retry reason =
      let backoff = Float.min 20. (0.5 *. (2. ** float_of_int (attempt - 1))) in
      let delay = backoff *. (0.5 +. Random.float 1.0) in
      Log.warn "http-proxy %s: %s; retrying (%d/%d) in %.1fs" op reason attempt
        max_attempts delay;
      let* () = Lwt_unix.sleep delay in
      go (attempt + 1)
    in
    match outcome with
      | `Ret (resp, body) when code resp >= 500 && attempt < max_attempts ->
          retry (Printf.sprintf "HTTP %d: %s" (code resp) (excerpt body))
      | `Ret r -> Lwt.return r
      | `Raised Cancelled -> Lwt.fail Cancelled
      | `Raised exn when attempt < max_attempts ->
          retry (Printexc.to_string exn)
      | `Raised exn -> Lwt.fail exn
  in
  go 1

let obj_uri t key =
  Uri.with_path t.base_uri ("/o/" ^ Http_proxy.Wire.encode_key key)

let put t ~key ~data () =
  let+ resp, body = call_retry t ~meth:`PUT ~body:data "put" (obj_uri t key) in
  if not (is_ok resp) then raise (backend_error "put" (code resp) body)

let get t ~key () =
  let+ resp, body = call_retry t ~meth:`GET "get" (obj_uri t key) in
  if is_ok resp then body else raise (backend_error "get" (code resp) body)

let get_opt t ~key () =
  let+ resp, body = call_retry t ~meth:`GET "get_opt" (obj_uri t key) in
  if is_ok resp then Some body
  else if code resp = 404 then None
  else raise (backend_error "get_opt" (code resp) body)

let head_opt t ~key () =
  let+ resp, body = call_retry t ~meth:`HEAD "head" (obj_uri t key) in
  if is_ok resp then (
    let h = Cohttp.Response.headers resp in
    let size =
      match Cohttp.Header.get h "x-tsync-size" with
        | Some s -> int_of_string s
        | None -> 0
    in
    let last_modified =
      match Cohttp.Header.get h "x-tsync-last-modified" with
        | Some s -> float_of_string s
        | None -> 0.
    in
    Some { Backend.key; size; last_modified })
  else if code resp = 404 then None
  else raise (backend_error "head" (code resp) body)

let delete t ~key () =
  let+ resp, body = call_retry t ~meth:`DELETE "delete" (obj_uri t key) in
  if not (is_ok resp) then raise (backend_error "delete" (code resp) body)

let delete_multi t keys =
  let body =
    Yojson.Safe.to_string (`List (List.map (fun k -> `String k) keys))
  in
  let uri = Uri.with_path t.base_uri "/delete-multi" in
  let+ resp, rbody = call_retry t ~meth:`POST ~body "delete_multi" uri in
  if not (is_ok resp) then
    raise (backend_error "delete_multi" (code resp) rbody)

let copy t ~src_key ~dst_key () =
  let uri =
    Uri.with_query'
      (Uri.with_path t.base_uri "/copy")
      [("src", src_key); ("dst", dst_key)]
  in
  let+ resp, body = call_retry t ~meth:`POST "copy" uri in
  if not (is_ok resp) then raise (backend_error "copy" (code resp) body)

let list_all t ?max_keys ~prefix () =
  let query =
    [("mode", "all"); ("prefix", prefix)]
    @
      match max_keys with
      | Some n -> [("max_keys", string_of_int n)]
      | None -> []
  in
  let uri = Uri.with_query' (Uri.with_path t.base_uri "/list") query in
  let+ resp, body = call_retry t ~meth:`GET "list_all" uri in
  if is_ok resp then Http_proxy.Wire.entries_of_json body
  else raise (backend_error "list_all" (code resp) body)

(* The proxy's own setting, asked rather than mirrored in client config where the
   two could disagree. It answers yes/no only: behind TLS termination it does not
   reliably know its own public URL, while [base_uri] is exactly the URL this
   client reaches it on. *)
let query_share_url t ~prefix =
  let uri =
    Uri.with_query' (Uri.with_path t.base_uri "/share-url") [("prefix", prefix)]
  in
  let+ resp, body = call_retry t ~meth:`GET "share_url" uri in
  if is_ok resp then (
    match Yojson.Safe.from_string body with
      | exception _ -> None
      | j -> (
          match
            (Yojson.Safe.Util.member "url" j, Yojson.Safe.Util.member "self" j)
          with
            (* A backing store serves them: absolute URL, used as given. *)
            | `String url, _ -> Some url
            (* The proxy serves them itself, off the address we reach it on. *)
            | _, `Bool true ->
                Some (Uri.to_string (Uri.with_path t.base_uri "/s"))
            | _ -> None))
  else if code resp = 404 then None
  else raise (backend_error "share_url" (code resp) body)

(* Fixed for the life of the process, so the promise is memoized and concurrent
   callers share one request. *)
let share_url t ~prefix () =
  match t.share_url_cache with
    | Some p -> p
    | None ->
        let p = query_share_url t ~prefix in
        t.share_url_cache <- Some p;
        p

(* The serving domain's own [chunkSize], so a client behind the proxy writes new
   files at the size the domain uses instead of the two configs having to agree.
   404 means no opinion. *)
let query_chunk_size t ~prefix =
  let uri =
    Uri.with_query'
      (Uri.with_path t.base_uri "/chunk-size")
      [("prefix", prefix)]
  in
  let+ resp, body = call_retry t ~meth:`GET "chunk_size" uri in
  if is_ok resp then (
    match Yojson.Safe.from_string body with
      | exception _ -> None
      | j -> (
          match Yojson.Safe.Util.member "chunkSize" j with
            | `Int n when n > 0 -> Some n
            | _ -> None))
  else if code resp = 404 then None
  else raise (backend_error "chunk_size" (code resp) body)

(* Fixed for the process, like {!share_url}: a change would only affect files
   created next, and re-asking per upload costs a round trip each time. *)
let default_chunk_size t ~prefix () =
  match t.chunk_size_cache with
    | Some p -> p
    | None ->
        let p = query_chunk_size t ~prefix in
        t.chunk_size_cache <- Some p;
        p

(* What the serving proxy will run at once, so a client holds its own excess
   rather than parking it in the server's accept queue. The limit belongs to
   hardware this process cannot see, which is why it is asked for rather than
   configured twice. 404 means no bound. *)
let query_max_concurrency t ~prefix =
  let uri =
    Uri.with_query'
      (Uri.with_path t.base_uri "/max-concurrency")
      [("prefix", prefix)]
  in
  let+ resp, body = call_retry t ~meth:`GET "max_concurrency" uri in
  if is_ok resp then (
    match Yojson.Safe.from_string body with
      | exception _ -> None
      | j -> (
          match Yojson.Safe.Util.member "maxConcurrency" j with
            | `Int n when n > 0 -> Some n
            | _ -> None))
  else if code resp = 404 then None
  else raise (backend_error "max_concurrency" (code resp) body)

(* Asked once: a peer changing its bound restarts to do it, dropping these
   connections anyway. *)
let max_concurrency t ~prefix () =
  match t.max_concurrency_cache with
    | Some p -> p
    | None ->
        let p = query_max_concurrency t ~prefix in
        t.max_concurrency_cache <- Some p;
        p

let make ~url ~secret : (module Backend.S) =
  let t =
    {
      base_uri = Uri.of_string url;
      secret;
      cache = Cache.create ~keep:keep_idle_ns ~parallel:max_parallel ();
      share_url_cache = None;
      chunk_size_cache = None;
      max_concurrency_cache = None;
    }
  in
  (module struct
    let put ~key ~data () = put t ~key ~data ()
    let get ~key () = get t ~key ()
    let get_opt ~key () = get_opt t ~key ()
    let head_opt ~key () = head_opt t ~key ()
    let delete ~key () = delete t ~key ()
    let delete_multi keys = delete_multi t keys
    let copy ~src_key ~dst_key () = copy t ~src_key ~dst_key ()
    let list_prefix ?max_keys ~prefix () = list_all t ?max_keys ~prefix ()
    let share_url ~prefix () = share_url t ~prefix ()
    let default_chunk_size ~prefix () = default_chunk_size t ~prefix ()
    let max_concurrency ~prefix () = max_concurrency t ~prefix ()
  end)

let spec =
  Backend.
    [
      {
        name = "url";
        label = "Proxy URL (http(s)://host[:port])";
        typ = `String;
        default = None;
        secret = false;
      };
      {
        name = "secret";
        label = "Shared secret";
        typ = `String;
        default = None;
        secret = true;
      };
    ]

let () =
  let req get key =
    match get key with
      | Some v -> v
      | None -> failwith ("http-proxy backend: missing field: " ^ key)
  in
  Backend.register ~spec "http-proxy" (fun get ->
      make ~url:(req get "url") ~secret:(req get "secret"))
