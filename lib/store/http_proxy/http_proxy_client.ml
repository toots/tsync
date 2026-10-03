open Tsync_core

let fields =
  Field_spec.
    [
      f ~required:true
        ~check:(http_url ~bare_host:false)
        "url" "Server URL" String;
      f ~secret:true ~required:true ~check:secret_length "secret"
        "Shared secret" String;
      f ~check:absolute_path "ca_certificate" "CA bundle" Path;
    ]

open Tsync_store
module W = Proxy_wire

let stall_timeout = 300.
let watch_floor = 2.

type t = {
  name : string;
  domain : Domain_name.t;
  secret : string;
  endpoint : Tsync_http.Client.endpoint;
  health : Health.t;
  traffic : Store.traffic;
  admission : Uplink.t;
  served : bool option Atomic.t;
  claims : bool option Atomic.t;
  checksums : bool option Atomic.t;
      (** the server answers /checksum, and so honours if_match *)
  caps : (string * Store.caps) list Atomic.t;
  no_get_many : bool Atomic.t;
  no_list_many : bool Atomic.t;
}

type answer = Tsync_http.Client.response

let success s = s >= 200 && s < 300

(* §3.3: a 401 whose Date is off by more than the window is clock skew, not a
   bad secret. *)
let skewed (r : answer) =
  match
    Option.bind
      (Tsync_http.Codec.header r.headers "date")
      Tsync_http.Codec.parse_http_date
  with
    | Some t -> Float.abs (t -. Unix.gettimeofday ()) > W.max_clock_skew
    | None -> false

(* §6.3: statuses as failure kinds; a considered answer never climbs the
   ladder. *)
let failure t ~op (r : answer) =
  let text = Tsync_http.Client.excerpt r.body in
  let reason = Printf.sprintf "%s %s: HTTP %d: %s" t.name op r.status text in
  let kind =
    match r.status with
      | 404 -> Fail.Denied
      | 400 | 413 | 414 | 431 -> Fail.Invalid
      | 401 when skewed r -> Fail.Link
      | 401 -> Fail.Denied
      | 403 -> Fail.Read_only
      | 409 -> (
          match Tsync_http.Codec.header r.headers "x-tsync-kind" with
            | Some "missing_chunks" ->
                Fail.Missing_chunks
                  (List.filter
                     (fun l ->
                       l <> "" && l <> "missing chunks"
                       && Chunk_key.of_string l <> None)
                     (String.split_on_char '\n' (Bigstring.to_string r.body)))
            | Some k -> Fail.of_wire_kind k
            | None -> Fail.Refused)
      | 429 | 503 -> Fail.Load
      | s when s >= 500 -> Fail.Link
      | _ -> Fail.Refused
  in
  let reason =
    if r.status = 401 && skewed r then
      reason
      ^ " (clock skew: this clock and the server's differ by more than 5 \
         minutes)"
    else reason
  in
  raise (Fail.E (Fail.make ~op kind reason))

let request ?(mode = Store.Wait) ?(headers = []) t ~meth ?(query = [])
    ?(body = Bigstring.empty) path =
  let target =
    if query = [] then path else path ^ "?" ^ W.canonical_query query
  in
  let send () =
    ignore (Atomic.fetch_and_add t.traffic.uploaded (Bigstring.length body));
    Tsync_http.Client.request ~stall:stall_timeout t.endpoint ~meth
      ?body:(if meth = "PUT" || meth = "POST" then Some body else None)
      ~headers:(fun () -> headers @ W.sign ~secret:t.secret ~meth ~target body)
      target
  in
  let r =
    if Bigstring.length body = 0 then send ()
    else Uplink.admitted t.admission mode (Bigstring.length body) send
  in
  ignore (Atomic.fetch_and_add t.traffic.downloaded (Bigstring.length r.body));
  r

let ladder t op f = Retry.ladder ~health:t.health ~op f
let obj k = "/o/" ^ W.encode_key k
let empty_404 (r : answer) = r.status = 404 && Bigstring.length r.body = 0

(* §8.1: learned once per instance, forgotten when asking failed; only a
   considered 404 is remembered, since a 401 may be this clock's skew. *)
let ensure_served t =
  match Atomic.get t.served with
    | Some true -> ()
    | Some false ->
        Fail.raise_ Fail.Denied "%s: domain not served by %s" t.name
          (Tsync_http.Client.url t.endpoint)
    | None -> (
        let r =
          ladder t "bind" (fun () ->
              let r =
                request t ~meth:"GET"
                  ~query:
                    [
                      ("mode", "all");
                      ("prefix", Key.to_string (Key.cursor t.domain));
                      ("max_keys", "1");
                    ]
                  "/list"
              in
              if r.status >= 500 || r.status = 429 then failure t ~op:"bind" r
              else r)
        in
        match r.status with
          | s when success s -> Atomic.set t.served (Some true)
          | 404 when not (empty_404 r) ->
              Atomic.set t.served (Some false);
              Fail.raise_ Fail.Denied "%s: domain not served by %s" t.name
                (Tsync_http.Client.url t.endpoint)
          | _ -> failure t ~op:"bind" r)

let call ?mode ?headers t op ~meth ?query ?body path =
  ensure_served t;
  ladder t op (fun () ->
      let r = request ?mode ?headers t ~meth ?query ?body path in
      match r.status with
        | 429 | 503 -> failure t ~op r
        | s when s >= 500 -> failure t ~op r
        | _ -> r)

let expect t op (r : answer) = if not (success r.status) then failure t ~op r

let capability t prefix path =
  match
    request t ~meth:"GET" ~query:[("prefix", Key.prefix_to_string prefix)] path
  with
    | r when success r.status -> (
        (* Not a tsync server's answer (a captive portal): nothing to keep. *)
        try Some (Yojson.Safe.from_string (Bigstring.to_string r.body))
        with _ ->
          Fail.corrupt "%s answered %s with something that is not JSON" t.name
            path)
    | { status = 404; _ } -> None
    | r -> failure t ~op:path r

let positive j k =
  match j with
    | Some (`Assoc l) -> (
        match List.assoc_opt k l with
          | Some (`Int n) when n > 0 -> Some n
          | _ -> None)
    | _ -> None

(* §8.4: four questions at once, the answer kept per prefix for the instance's
   life; claims are known supported once /verified answers. *)
let capabilities t prefix =
  let key = Key.prefix_to_string prefix in
  match List.assoc_opt key (Atomic.get t.caps) with
    | Some c -> c
    | None ->
        ensure_served t;
        let answers =
          ladder t "capabilities" (fun () ->
              Rt.map_concurrently (capability t prefix)
                ["/share-url"; "/chunk-size"; "/max-concurrency"; "/verified"])
        in
        let share, chunk, conc, verified =
          match answers with [a; b; c; d] -> (a, b, c, d) | _ -> assert false
        in
        Atomic.set t.claims (Some (verified <> None));
        let share_url =
          match share with
            | Some (`Assoc l) -> (
                match (List.assoc_opt "self" l, List.assoc_opt "url" l) with
                  | Some (`Bool true), _ ->
                      Some (Tsync_http.Client.url t.endpoint ^ "/s")
                  | _, Some (`String u) -> Some u
                  | _ -> None)
            | _ -> None
        in
        let c =
          {
            Store.share_url;
            chunk_size = positive chunk "chunkSize";
            max_concurrency = positive conc "maxConcurrency";
            verified =
              (match verified with
                | Some (`Assoc l) ->
                    List.assoc_opt "verified" l = Some (`Bool true)
                | _ -> false);
          }
        in
        let rec keep () =
          let l = Atomic.get t.caps in
          if not (Atomic.compare_and_set t.caps l ((key, c) :: l)) then keep ()
        in
        keep ();
        c

let claims_supported t =
  match Atomic.get t.claims with
    | Some b -> b
    | None ->
        ignore (capabilities t (Key.domain_prefix t.domain));
        Option.value ~default:false (Atomic.get t.claims)

let put_if_absent t k body =
  if Bigstring.length body = 0 then Fail.invalid "%s: an empty claim" t.name;
  if not (claims_supported t) then
    Fail.raise_ Fail.Refused "%s: server lacks conditional create" t.name;
  let r =
    call t "put_if_absent" ~meth:"PUT" ~query:[("if_absent", "1")] ~body (obj k)
  in
  expect t "put_if_absent" r;
  if Bigstring.length r.body = 0 then
    Fail.corrupt "%s: an empty answer to a claim" t.name
  else if Bigstring.equal r.body body then Store.Won
  else Held r.body

let checksum_request t k algo =
  call t "checksum" ~meth:"GET"
    ~query:[("algo", algo)]
    ("/checksum/" ^ W.encode_key k)

(* §8.1: a server that answers /checksum, even 404 with an empty body,
   honours if_match and if_none_match; a 404 with a body has neither. *)
let checksums_supported t =
  match Atomic.get t.checksums with
    | Some b -> b
    | None ->
        let r = checksum_request t (Key.cursor t.domain) Checksum.md5 in
        let supported =
          if success r.status || empty_404 r then true
          else if r.status = 404 then false
          else failure t ~op:"checksum" r
        in
        Atomic.set t.checksums (Some supported);
        supported

let get_opt t k =
  match call t "get" ~meth:"GET" (obj k) with
    | r when success r.status -> Some r.body
    | r when empty_404 r -> None
    | r -> failure t ~op:"get" r

let get_range t k off len =
  let r =
    call t "get_range" ~meth:"GET"
      ~query:[("offset", string_of_int off); ("length", string_of_int len)]
      (obj k)
  in
  match r with
    | r when success r.status ->
        if Bigstring.length r.body > len then
          Fail.corrupt "%s: asked %d bytes, got %d" t.name len
            (Bigstring.length r.body);
        Some r.body
    | r when empty_404 r -> None
    | r -> failure t ~op:"get_range" r

let head_opt t k =
  match call t "head" ~meth:"HEAD" (obj k) with
    | r when success r.status -> (
        let h = Tsync_http.Codec.header r.headers in
        match
          ( Option.bind (h "x-tsync-size") int_of_string_opt,
            Option.bind (h "x-tsync-last-modified") float_of_string_opt )
        with
          | Some size, Some last_modified ->
              Some
                {
                  Store.key = k;
                  size;
                  last_modified;
                  etag = h "x-tsync-etag";
                  checksum =
                    Option.bind (h "x-tsync-checksum") Checksum.of_string;
                }
          | _ -> Fail.corrupt "%s: a HEAD answer without size or time" t.name)
    | { status = 404; _ } -> None
    | r -> failure t ~op:"head" r

(* §8.2: hashed where the bytes are, on the server; downloaded and hashed here
   only against a server without the endpoint. *)
let compute_checksum t k algo =
  if checksums_supported t then (
    match checksum_request t k algo with
      | r when success r.status -> (
          match
            Checksum.of_string (String.trim (Bigstring.to_string r.body))
          with
            | Some c when c.algo = algo -> Some c
            | _ -> Fail.corrupt "%s: a checksum answer that is not one" t.name)
      | r when empty_404 r -> None
      | r -> failure t ~op:"checksum" r)
  else Option.map (Checksum.of_body algo) (get_opt t k)

let put_if_unchanged t k body (expected : Store.entry option) =
  if not (checksums_supported t) then
    Fail.raise_ Fail.Refused "%s: server lacks conditional replace" t.name;
  let query =
    match expected with
      | None -> [("if_none_match", "1")]
      | Some { etag = Some etag; _ } -> [("if_match", etag)]
      | Some { etag = None; _ } ->
          Fail.raise_ Fail.Refused "%s: no version to replace against" t.name
  in
  match call t "put_if_unchanged" ~meth:"PUT" ~query ~body (obj k) with
    | r when success r.status -> Store.Written
    | { status = 412; _ } -> Changed
    | r -> failure t ~op:"put_if_unchanged" r

let delete t k =
  match call t "delete" ~meth:"DELETE" (obj k) with
    | { status = 204; _ } -> false
    | r when empty_404 r -> false
    | r when success r.status -> true
    | r -> failure t ~op:"delete" r

let rec pages n = function
  | [] -> []
  | l ->
      let rec take k acc = function
        | x :: rest when k > 0 -> take (k - 1) (x :: acc) rest
        | rest -> (List.rev acc, rest)
      in
      let page, rest = take n [] l in
      page :: pages n rest

let json_keys keys =
  Bigstring.of_string
    (Yojson.Safe.to_string
       (`List (List.map (fun k -> `String (Key.to_string k)) keys)))

let delete_multi t keys =
  List.iter
    (fun page ->
      expect t "delete_multi"
        (call t "delete_multi" ~meth:"POST" ~body:(json_keys page)
           "/delete-multi"))
    (pages W.bulk_keys_max keys)

(* §8.3: a 404 with a body on a served domain means the endpoint is missing;
   the instance falls back for its life. *)
let get_many t keys =
  if Atomic.get t.no_get_many then List.map (get_opt t) keys
  else (
    (* The server may answer the first keys only, to bound its answer: the
       rest is asked again. *)
    let rec page_of keys =
      match
        call t "get_many" ~meth:"POST"
          ~headers:[(W.partial_header, "1")]
          ~body:(json_keys keys) "/get-multi"
      with
        | r when success r.status ->
            let got = W.decode_bodies ~count:(List.length keys) r.body in
            let rest = List.filteri (fun i _ -> i >= List.length got) keys in
            if rest = [] then got else got @ page_of rest
        | { status = 404; _ } ->
            Atomic.set t.no_get_many true;
            List.map (get_opt t) keys
        | r -> failure t ~op:"get_many" r
    in
    List.concat_map page_of (pages W.bulk_keys_max keys))

let list_many t prefixes =
  if Atomic.get t.no_list_many then []
  else
    List.concat_map
      (fun page ->
        let body =
          Bigstring.of_string
            (Yojson.Safe.to_string
               (`List
                  (List.map (fun p -> `String (Key.prefix_to_string p)) page)))
        in
        match call t "list_many" ~meth:"POST" ~body "/children-multi" with
          | r when success r.status -> W.decode_folders ~asked:page r.body
          | { status = 404; _ } ->
              Atomic.set t.no_list_many true;
              []
          | r -> failure t ~op:"list_many" r)
      (pages W.bulk_folders_max prefixes)

let list_prefix t ?max_keys prefix =
  let r =
    call t "list" ~meth:"GET"
      ~query:
        ([("mode", "all"); ("prefix", Key.prefix_to_string prefix)]
        @ Option.fold ~none:[]
            ~some:(fun n -> [("max_keys", string_of_int n)])
            max_keys)
      "/list"
  in
  expect t "list" r;
  W.listing_of_json (Bigstring.to_string r.body)

(* §7: one attempt outside the ladder; a server without watch support, or any
   failure, costs the floor. *)
let watch t k last =
  let query =
    (match last with Some tok -> [("last_seen", tok)] | None -> [])
    @ [("wait", "30")]
  in
  match
    ensure_served t;
    request t ~meth:"GET" ~query (obj k)
  with
    | r when Tsync_http.Codec.header r.headers "x-tsync-watched" <> None ->
        Health.answered t.health
    | _ -> Stop.sleep watch_floor
    | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
    | exception e ->
        (match e with
          | Fail.E { kind = Link; reason; _ } ->
              ignore (Health.lost ~reason t.health)
          | _ -> ());
        Stop.sleep watch_floor

let create ~domain ~admission ~name fields =
  let str k =
    match List.assoc_opt k fields with
      | Some (Field_spec.S s) when String.trim s <> "" -> Some (String.trim s)
      | _ -> None
  in
  let url =
    match str "url" with
      | Some u ->
          if String.ends_with ~suffix:"/" u then
            String.sub u 0 (String.length u - 1)
          else u
      | None -> Fail.invalid "backend %s: no url" name
  in
  let secret =
    match str "secret" with
      | Some s -> s
      | None -> Fail.invalid "backend %s: no secret" name
  in
  let t =
    {
      name;
      domain;
      secret;
      endpoint = Tsync_http.Client.endpoint ?ca_file:(str "ca_certificate") url;
      health = Health.create name;
      traffic = Store.new_traffic ();
      admission;
      served = Atomic.make None;
      claims = Atomic.make None;
      checksums = Atomic.make None;
      caps = Atomic.make [];
      no_get_many = Atomic.make false;
      no_list_many = Atomic.make false;
    }
  in
  Store.checked
    {
      Store.name;
      put =
        (fun ?mode k body ->
          expect t "put" (call ?mode t "put" ~meth:"PUT" ~body (obj k)));
      put_if_absent = put_if_absent t;
      put_if_unchanged = put_if_unchanged t;
      get_opt = get_opt t;
      get_range = get_range t;
      head_opt = head_opt t;
      compute_checksum = compute_checksum t;
      delete = delete t;
      delete_multi = delete_multi t;
      copy =
        (fun src dst ->
          expect t "copy"
            (call t "copy" ~meth:"POST"
               ~query:[("src", Key.to_string src); ("dst", Key.to_string dst)]
               "/copy"));
      list_prefix = (fun ?max_keys p -> list_prefix t ?max_keys p);
      watch = watch t;
      get_many = Some (get_many t);
      list_many = Some (list_many t);
      bucket_functions = false;
      capabilities = capabilities t;
      fast_read = false;
      locality = Proxy;
      local_path = None;
      health = t.health;
      traffic = Some t.traffic;
    }

let () =
  Tsync_store.Driver.register "http-proxy" { fields; linkless = false; create }
