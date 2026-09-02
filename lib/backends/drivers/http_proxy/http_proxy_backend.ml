module Over
    (Io : Io.S)
    (Hc : Http_client.S with type 'a io := 'a Io.t)
    (Clock : Clock.S with type 'a io := 'a Io.t) =
struct
  module type Store = Backend.S with type 'a io := 'a Io.t

  open Io_syntax.Make (Io)

  (* Both at once, which is the point of asking this way: [join] is what starts
     them together, and neither result is read before it has landed. *)
  let ( and* ) a b =
    let ra = ref None and rb = ref None in
    let+ () =
      Io.join
        [Io.map (fun x -> ra := Some x) a; Io.map (fun y -> rb := Some y) b]
    in
    (Option.get !ra, Option.get !rb)

  let ( and+ ) = ( and* )

  (* A stall detector, not a latency budget: a pooled connection whose peer went
     away without a FIN leaves its request pending forever, and [call_retry] only
     ever sees failures, never stalls. Generous enough for a chunk over a slow
     link. *)
  let request_timeout = 300.

  type t = {
    base_uri : Uri.t;
    secret : string;
    client : Hc.t;
    mutable caps_cache : Backend.caps Io.t option;
  }

  let code = Http_client.code
  let is_ok = Http_client.is_ok
  let failed = Http_client.failed

  (* Signs method + request-target + body with the shared secret; TLS is
     conduit's, per the global [Tls_conf]. Nothing here reaches the network, but
     the pool takes a thunk because another driver's does. *)
  let headers t ~meth ~uri ~body () =
    Io.return
      (Cohttp.Header.of_list
         (Http_proxy.Auth.request_headers ~secret:t.secret
            ~meth:(Cohttp.Code.string_of_method meth)
            ~path:(Uri.path_and_query uri) ~body ()))

  (* Every proxied operation is idempotent, so retrying is safe. *)
  let call_retry t ~meth ?(body = Bigstring.empty) op uri =
    Hc.call_retry t.client
      ~headers:(headers t ~meth ~uri ~body)
      ~meth ~body op uri

  let call_text t ~meth ?(body = Bigstring.empty) op uri =
    Hc.call_text t.client
      ~headers:(headers t ~meth ~uri ~body)
      ~meth ~body op uri

  let obj_uri t key =
    Uri.with_path t.base_uri ("/o/" ^ Http_proxy.Wire.encode_key key)

  let put t ~key ~data () =
    let+ resp, body =
      call_retry t ~meth:`PUT ~body:data "put" (obj_uri t key)
    in
    if not (is_ok resp) then
      raise (failed "put" (code resp) (Bigstring.to_string body))

  (* The serving side arbitrates, holding the store, and the reply body is
     whatever ended up at the key. A proxy too old to know the parameter would
     treat this as a plain put and answer its own body, which reads as "you won",
     so the two sides must be of a version. *)
  let put_if_absent t ~key ~data () =
    let uri = Uri.add_query_param' (obj_uri t key) ("if_absent", "1") in
    let+ resp, body = call_retry t ~meth:`PUT ~body:data "put_if_absent" uri in
    if is_ok resp then body
    else raise (failed "put_if_absent" (code resp) (Bigstring.to_string body))

  let get t ~key () =
    let+ resp, body = call_retry t ~meth:`GET "get" (obj_uri t key) in
    if is_ok resp then body
    else raise (failed "get" (code resp) (Bigstring.to_string body))

  let get_opt t ~key () =
    let+ resp, body = call_retry t ~meth:`GET "get_opt" (obj_uri t key) in
    if is_ok resp then Some body
    else if code resp = 404 then None
    else raise (failed "get_opt" (code resp) (Bigstring.to_string body))

  (* In the query rather than a [Range] header, which is what the signature
     already covers: it is taken over the request target, so a tampered offset
     does not verify. A peer too old to know these answers the whole object and
     is caught by {!Backend.checked_range}, rather than serving a body that
     silently is not the range asked for. *)
  let get_range t ~key ~offset ~length () =
    let uri =
      Uri.with_query' (obj_uri t key)
        [("offset", string_of_int offset); ("length", string_of_int length)]
    in
    let+ resp, body = call_retry t ~meth:`GET "get_range" uri in
    if is_ok resp then
      Some (Backend.checked_range ~op:"http-proxy" ~key ~length body)
    else if code resp = 404 then None
    else raise (failed "get_range" (code resp) (Bigstring.to_string body))

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
      Some
        {
          Backend.key = Stored_key.listed key;
          size;
          last_modified;
          etag = None;
        })
    else if code resp = 404 then None
    else raise (failed "head" (code resp) body)

  (* A key that is not there is not a failure, as {!Backend.S.delete} promises
     and the other drivers keep. *)
  let delete t ~key () =
    let+ resp, body = call_text t ~meth:`DELETE "delete" (obj_uri t key) in
    if not (is_ok resp) && code resp <> 404 then
      raise (failed "delete" (code resp) body)

  let delete_multi t keys =
    let body =
      Yojson.Safe.to_string
        (`List (List.map (fun k -> `String (Stored_key.to_string k)) keys))
    in
    let uri = Uri.with_path t.base_uri "/delete-multi" in
    let+ resp, rbody =
      call_text t ~meth:`POST ~body:(Bigstring.of_string body) "delete_multi"
        uri
    in
    if not (is_ok resp) then raise (failed "delete_multi" (code resp) rbody)

  (* The one operation the proxy saves a round trip on: the peer holds the objects
     and can answer a folder's worth in a single response, where an object store
     would have to be asked key by key. *)
  let get_many t ~entries () =
    let keys =
      List.map (fun (e : Backend.file_entry) -> e.Backend.key) entries
    in
    let body =
      Yojson.Safe.to_string
        (`List (List.map (fun k -> `String (Stored_key.to_string k)) keys))
    in
    let uri = Uri.with_path t.base_uri "/get-multi" in
    let+ resp, answer =
      call_retry t ~meth:`POST ~body:(Bigstring.of_string body) "get_many" uri
    in
    if is_ok resp then
      Http_proxy.Wire.bodies_of_string ~keys (Bigstring.to_string answer)
    else raise (failed "get_many" (code resp) (Bigstring.to_string answer))

  let copy t ~src_key ~dst_key () =
    let uri =
      Uri.with_query'
        (Uri.with_path t.base_uri "/copy")
        [("src", src_key); ("dst", dst_key)]
    in
    let+ resp, body = call_text t ~meth:`POST "copy" uri in
    if not (is_ok resp) then raise (failed "copy" (code resp) body)

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
    else raise (failed "list_all" (code resp) body)

  (* The proxy answers yes/no only: behind TLS termination it does not reliably
     know its own public URL, while [base_uri] is exactly the URL this client
     reaches it on. *)
  let query_share_url t ~prefix =
    let uri =
      Uri.with_query'
        (Uri.with_path t.base_uri "/share-url")
        [("prefix", prefix)]
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
    else raise (failed "share_url" (code resp) body)

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
    else raise (failed "chunk_size" (code resp) body)

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
    else raise (failed "max_concurrency" (code resp) body)

  (* 404 reads as [false], which is the honest answer twice over: a proxy too old
     to have this endpoint is one whose store nothing was checking when it was
     built, and a peer that cannot say whether its bytes are held against their
     names has not said they are. *)
  let query_verified t ~prefix =
    let uri =
      Uri.with_query'
        (Uri.with_path t.base_uri "/verified")
        [("prefix", prefix)]
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
    else raise (failed "verified" (code resp) body)

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
            (* [verified] is asked over the wire because it is a fact about the
               bytes rather than about machinery, and the markers it describes are
               ones we go on to list through this same peer. *)
            Io.return
              { Backend.share_url; chunk_size; max_concurrency; verified }
          in
          t.caps_cache <- Some p;
          p

  let make ~url ~secret : (module Store) =
    let t =
      {
        base_uri = Uri.of_string url;
        secret;
        client =
          Hc.create ~name:"http-proxy" ~timeout:request_timeout
            ~classify:Backend.classify ();
        caps_cache = None;
      }
    in
    (* Every key the store is asked about is rendered here, this module being the
       one place the driver is reached through. *)
    let str = Stored_key.to_string in
    (module struct
      let put ~key ~data () = put t ~key:(str key) ~data ()
      let put_if_absent ~key ~data () = put_if_absent t ~key:(str key) ~data ()
      let get ~key () = get t ~key:(str key) ()
      let get_opt ~key () = get_opt t ~key:(str key) ()
      let fast_read = false

      let get_range ~key ~offset ~length () =
        get_range t ~key:(str key) ~offset ~length ()

      let head_opt ~key () = head_opt t ~key:(str key) ()
      let delete ~key () = delete t ~key:(str key) ()
      let delete_multi keys = delete_multi t keys

      let copy ~src_key ~dst_key () =
        copy t ~src_key:(str src_key) ~dst_key:(str dst_key) ()

      let list_prefix ?max_keys ~prefix () = list_all t ?max_keys ~prefix ()
      let get_many = Some (fun ~entries () -> get_many t ~entries ())

      (* The peer owns that store and whatever checks it; asking it to start a
         sweep on our behalf is a decision for whoever administers it. *)
      let verify_all ~chunk_prefix:_ () = Io.return `Unsupported

      (* Enqueueing work in the peer's own bucket is not this client's to decide,
         and the peer's store is reached through the bulk delete either way. *)
      let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
        Io.return `Unsupported

      let capabilities ~prefix () = capabilities t ~prefix ()

      (* Asked of the peer rather than slept out here: it holds the request
         until the object differs, so a change crosses the link when it happens
         instead of on the next tick, and one peer watching its own store
         answers every client waiting on it.

         How long, and what to call the parameters, are {!Http_proxy.Watch}'s:
         the peer reads what this writes. *)
      let watch ~key ~last_seen () =
        let uri =
          Uri.add_query_param'
            (obj_uri t (str key))
            ( Http_proxy.Watch.wait_param,
              Printf.sprintf "%g" Http_proxy.Watch.max_seconds )
        in
        let uri =
          match last_seen with
            | None -> uri
            | Some token ->
                Uri.add_query_param' uri
                  ( Http_proxy.Watch.last_seen_param,
                    Backend.Watch_token.to_wire token )
        in
        let* answered =
          Io.catch
            (fun () ->
              let+ resp, (_ : Bigstring.t) =
                call_retry t ~meth:`GET "watch" uri
              in
              Cohttp.Header.get
                (Cohttp.Response.headers resp)
                Http_proxy.Watch.answered_header)
            (fun (_ : exn) -> Io.return None)
        in
        match answered with
          | Some (_ : string) -> Io.return ()
          (* A peer too old to know the parameter reads this as a plain get and
             answers at once, and a failed request costs no time either. Without
             a floor, both are a caller spinning. *)
          | None -> Clock.sleep Backend.default_watch_interval

      (* The peer's files are the peer's, whatever it keeps them on. *)
      let local_path = None
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
end
