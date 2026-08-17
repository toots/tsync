open Lwt.Syntax

exception Cancelled = Backend.Cancelled

(* Pooled per endpoint rather than per request: a full resync fetches tens of
   thousands of objects, and a handshake each caps throughput at a few dozen a
   second while leaving thousands of sockets in TIME_WAIT. *)
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
  mutable cache : Cache.t;
  mutable caps_cache : Backend.caps Lwt.t option;
}

(* The connection cache has no deadline of its own: a pooled connection whose
   peer went away without a FIN leaves its request pending forever, and
   [call_retry] only ever sees failures, never stalls.

   A stall detector, not a latency budget, hence generous enough for a chunk
   over a slow link. *)
let request_timeout = 300.

(* A 5xx is the serving side struggling; a 4xx is its answer. *)
let is_transient_code c = c >= 500

let backend_error op code body =
  Backend.failed
    ~kind:
      (if is_transient_code code then Backend.Transient else Backend.Permanent)
    ~op
    (Printf.sprintf "HTTP %d: %s" code body)

let new_cache () = Cache.create ~keep:keep_idle_ns ~parallel:max_parallel ()

(* Signs method + request-target + body with the shared secret; TLS is
   conduit's, per the global [Tls_conf].

   [Connection.Retry] means the pooled connection was unusable and the request
   never left, and one torn down by [request_timeout] above stays in the cache's
   table as permanently failed, so only a new cache redials. It is replaced once
   per generation, so requests that raced into the same dead pool share the one
   redial. *)
let call t ~meth ?(body = Chunk.empty) uri =
  let resource = Uri.path_and_query uri in
  let headers =
    Cohttp.Header.of_list
      (Http_proxy.Auth.request_headers ~secret:t.secret
         ~meth:(Cohttp.Code.string_of_method meth)
         ~path:resource ~body ())
  in
  let attempt cache =
    Lwt_unix.with_timeout request_timeout (fun () ->
        let* resp, rbody =
          Cache.call cache ~headers
            ~body:(Cohttp_lwt.Body.of_bigstring (Chunk.buffer body))
            meth uri
        in
        let+ body = Cohttp_lwt.Body.to_bigstring rbody in
        (resp, Chunk.of_buffer body))
  in
  let used = t.cache in
  Lwt.catch
    (fun () -> attempt used)
    (function
      | Connection.Retry ->
          if t.cache == used then t.cache <- new_cache ();
          attempt t.cache
      | exn -> Lwt.fail exn)

let code resp = Cohttp.Code.code_of_status (Cohttp.Response.status resp)
let is_ok resp = code resp >= 200 && code resp < 300

(* A proxy in front of us answers failures with a full HTML page, and one stalled
   fetch can put thousands of lines of nginx markup in the log; the status
   carries the meaning, one line of body only tells an upstream apart from our
   own answer. *)
let excerpt body =
  let body = String.trim body in
  match String.index_opt body '\n' with
    | _ when String.length body = 0 -> "(empty)"
    | Some i when i < 200 -> String.sub body 0 i ^ " ..."
    | _ when String.length body > 200 -> String.sub body 0 200 ^ " ..."
    | _ -> body

(* Raises on a transient status so the shared loop retries it; every other
   response comes back for the verb to interpret. Every proxied operation is
   idempotent, so retrying is safe. *)
let call_retry t ~meth ?body op uri =
  Backend.with_retry ~name:"http-proxy" ~op (fun () ->
      let* resp, rbody = call t ~meth ?body uri in
      if is_transient_code (code resp) then
        Lwt.fail
          (backend_error op (code resp) (excerpt (Chunk.to_string rbody)))
      else Lwt.return (resp, rbody))

(* Only the object verbs carry a body worth keeping off the heap; everything
   below answers with JSON or a sentence, and reads it as one. *)
let call_text t ~meth ?body op uri =
  let+ resp, rbody = call_retry t ~meth ?body op uri in
  (resp, Chunk.to_string rbody)

let obj_uri t key =
  Uri.with_path t.base_uri ("/o/" ^ Http_proxy.Wire.encode_key key)

let put t ~key ~data () =
  let+ resp, body = call_retry t ~meth:`PUT ~body:data "put" (obj_uri t key) in
  if not (is_ok resp) then
    raise (backend_error "put" (code resp) (Chunk.to_string body))

(* The serving side arbitrates, holding the store, and the reply body is
   whatever ended up at the key. A proxy too old to know the parameter would
   treat this as a plain put and answer its own body, which reads as "you won",
   so the two sides must be of a version. *)
let put_if_absent t ~key ~data () =
  let uri = Uri.add_query_param' (obj_uri t key) ("if_absent", "1") in
  let+ resp, body = call_retry t ~meth:`PUT ~body:data "put_if_absent" uri in
  if is_ok resp then body
  else raise (backend_error "put_if_absent" (code resp) (Chunk.to_string body))

let get t ~key () =
  let+ resp, body = call_retry t ~meth:`GET "get" (obj_uri t key) in
  if is_ok resp then body
  else raise (backend_error "get" (code resp) (Chunk.to_string body))

let get_opt t ~key () =
  let+ resp, body = call_retry t ~meth:`GET "get_opt" (obj_uri t key) in
  if is_ok resp then Some body
  else if code resp = 404 then None
  else raise (backend_error "get_opt" (code resp) (Chunk.to_string body))

let head_opt t ~key () =
  let+ resp, body = call_text t ~meth:`HEAD "head" (obj_uri t key) in
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
  let+ resp, body = call_text t ~meth:`DELETE "delete" (obj_uri t key) in
  if not (is_ok resp) then raise (backend_error "delete" (code resp) body)

let delete_multi t keys =
  let body =
    Yojson.Safe.to_string (`List (List.map (fun k -> `String k) keys))
  in
  let uri = Uri.with_path t.base_uri "/delete-multi" in
  let+ resp, rbody =
    call_text t ~meth:`POST ~body:(Chunk.of_string body) "delete_multi" uri
  in
  if not (is_ok resp) then
    raise (backend_error "delete_multi" (code resp) rbody)

let copy t ~src_key ~dst_key () =
  let uri =
    Uri.with_query'
      (Uri.with_path t.base_uri "/copy")
      [("src", src_key); ("dst", dst_key)]
  in
  let+ resp, body = call_text t ~meth:`POST "copy" uri in
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
  let+ resp, body = call_text t ~meth:`GET "list_all" uri in
  if is_ok resp then Http_proxy.Wire.entries_of_json body
  else raise (backend_error "list_all" (code resp) body)

(* The proxy answers yes/no only: behind TLS termination it does not reliably
   know its own public URL, while [base_uri] is exactly the URL this client
   reaches it on. *)
let query_share_url t ~prefix =
  let uri =
    Uri.with_query' (Uri.with_path t.base_uri "/share-url") [("prefix", prefix)]
  in
  let+ resp, body = call_text t ~meth:`GET "share_url" uri in
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

(* The serving domain's own [chunkSize], so a client behind the proxy writes new
   files at the size the domain uses instead of the two configs having to agree.
   404 means no opinion. *)
let query_chunk_size t ~prefix =
  let uri =
    Uri.with_query'
      (Uri.with_path t.base_uri "/chunk-size")
      [("prefix", prefix)]
  in
  let+ resp, body = call_text t ~meth:`GET "chunk_size" uri in
  if is_ok resp then (
    match Yojson.Safe.from_string body with
      | exception _ -> None
      | j -> (
          match Yojson.Safe.Util.member "chunkSize" j with
            | `Int n when n > 0 -> Some n
            | _ -> None))
  else if code resp = 404 then None
  else raise (backend_error "chunk_size" (code resp) body)

(* What the serving proxy will run at once, so a client holds its own excess
   rather than parking it in the server's accept queue. Asked rather than
   configured twice, the limit belonging to hardware this process cannot see;
   404 means no bound. *)
let query_max_concurrency t ~prefix =
  let uri =
    Uri.with_query'
      (Uri.with_path t.base_uri "/max-concurrency")
      [("prefix", prefix)]
  in
  let+ resp, body = call_text t ~meth:`GET "max_concurrency" uri in
  if is_ok resp then (
    match Yojson.Safe.from_string body with
      | exception _ -> None
      | j -> (
          match Yojson.Safe.Util.member "maxConcurrency" j with
            | `Int n when n > 0 -> Some n
            | _ -> None))
  else if code resp = 404 then None
  else raise (backend_error "max_concurrency" (code resp) body)

(* 404 reads as [false], which is the honest answer twice over: a proxy too old
   to have this endpoint is one whose store nothing was checking when it was
   built, and a peer that cannot say whether its bytes are held against their
   names has not said they are. *)
let query_verified t ~prefix =
  let uri =
    Uri.with_query' (Uri.with_path t.base_uri "/verified") [("prefix", prefix)]
  in
  let+ resp, body = call_text t ~meth:`GET "verified" uri in
  if is_ok resp then (
    match Yojson.Safe.from_string body with
      | exception _ -> false
      | j -> (
          match Yojson.Safe.Util.member "verified" j with
            | `Bool b -> b
            | _ -> false))
  else if code resp = 404 then false
  else raise (backend_error "verified" (code resp) body)

(* Fixed for the life of the process — a peer changing any of these restarts to
   do it, dropping these connections anyway — so the promise is memoized and
   concurrent callers share one set of requests.

   An endpoint each rather than one, so a client speaks to a proxy of any
   version. *)
let capabilities t ~prefix () =
  match t.caps_cache with
    | Some p -> p
    | None ->
        let p =
          let* share_url = query_share_url t ~prefix
          and* chunk_size = query_chunk_size t ~prefix
          and* max_concurrency = query_max_concurrency t ~prefix
          and* verified = query_verified t ~prefix in
          (* [gc] is not asked over the wire: collecting chunks needs a link and
             a rename in the store itself, which is the serving side's business
             and not something a proxy client can do on its behalf.

             [verified] is asked, because unlike collecting it is a fact about
             the bytes rather than about machinery, and the markers it describes
             are ones we go on to list through this same peer. *)
          Lwt.return
            {
              Backend.share_url;
              chunk_size;
              max_concurrency;
              gc = false;
              verified;
            }
        in
        t.caps_cache <- Some p;
        p

let make ~url ~secret : (module Backend.S) =
  let t =
    {
      base_uri = Uri.of_string url;
      secret;
      cache = new_cache ();
      caps_cache = None;
    }
  in
  (module struct
    let put ~key ~data () = put t ~key ~data ()
    let put_if_absent ~key ~data () = put_if_absent t ~key ~data ()
    let get ~key () = get t ~key ()
    let get_opt ~key () = get_opt t ~key ()
    let head_opt ~key () = head_opt t ~key ()
    let delete ~key () = delete t ~key ()
    let delete_multi keys = delete_multi t keys
    let copy ~src_key ~dst_key () = copy t ~src_key ~dst_key ()
    let list_prefix ?max_keys ~prefix () = list_all t ?max_keys ~prefix ()

    (* The peer owns that store and whatever checks it; asking it to start a
       sweep on our behalf is a decision for whoever administers it. *)
    let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

    (* Enqueueing work in the peer's own bucket is not this client's to decide,
       and the peer's store is reached through the bulk delete either way. *)
    let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
      Lwt.return `Unsupported

    let capabilities ~prefix () = capabilities t ~prefix ()
  end)

let spec =
  Field_spec.
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
