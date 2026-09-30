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
  caps : (string * Store.caps) list Atomic.t;
  no_get_many : bool Atomic.t;
  no_list_many : bool Atomic.t;
}

type answer = Tsync_http.Client.response

let success s = s >= 200 && s < 300

(* §3.3: a 401 whose Date is off by more than the window is clock skew, not a
   bad secret. *)
let months =
  [
    "Jan";
    "Feb";
    "Mar";
    "Apr";
    "May";
    "Jun";
    "Jul";
    "Aug";
    "Sep";
    "Oct";
    "Nov";
    "Dec";
  ]

(* An IMF-fixdate, "Wed, 30 Sep 2026 12:28:28 GMT". *)
let http_date d =
  try
    Scanf.sscanf d "%_s %d %s %d %d:%d:%d GMT" (fun day mon year h m sec ->
        let rec index i = function
          | [] -> None
          | x :: rest -> if x = mon then Some i else index (i + 1) rest
        in
        Option.bind (index 1 months) (fun month ->
            Option.map Ptime.to_float_s
              (Ptime.of_date_time ((year, month, day), ((h, m, sec), 0)))))
  with _ -> None

let skewed (r : answer) =
  match Option.bind (Tsync_http.Codec.header r.headers "date") http_date with
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

let request ?(mode = Store.Wait) t ~meth ?(query = []) ?(body = Bigstring.empty)
    path =
  let target =
    if query = [] then path else path ^ "?" ^ W.canonical_query query
  in
  let send () =
    ignore (Atomic.fetch_and_add t.traffic.uploaded (Bigstring.length body));
    Tsync_http.Client.request ~stall:stall_timeout t.endpoint ~meth
      ?body:(if meth = "PUT" || meth = "POST" then Some body else None)
      ~headers:(fun () -> W.sign ~secret:t.secret ~meth ~target body)
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

(* §8.1: learned once per instance, forgotten when asking failed. *)
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
          | 401 | 404 ->
              Atomic.set t.served (Some false);
              Fail.raise_ Fail.Denied "%s: domain not served by %s" t.name
                (Tsync_http.Client.url t.endpoint)
          | _ -> failure t ~op:"bind" r)

let call ?mode t op ~meth ?query ?body path =
  ensure_served t;
  ladder t op (fun () ->
      let r = request ?mode t ~meth ?query ?body path in
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
        try Some (Yojson.Safe.from_string (Bigstring.to_string r.body))
        with _ -> None)
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
                { Store.key = k; size; last_modified; etag = h "x-tsync-etag" }
          | _ -> Fail.corrupt "%s: a HEAD answer without size or time" t.name)
    | { status = 404; _ } -> None
    | r -> failure t ~op:"head" r

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
  else
    List.concat_map
      (fun page ->
        match
          call t "get_many" ~meth:"POST" ~body:(json_keys page) "/get-multi"
        with
          | r when success r.status ->
              W.decode_bodies ~count:(List.length page) r.body
          | { status = 404; _ } ->
              Atomic.set t.no_get_many true;
              List.map (get_opt t) page
          | r -> failure t ~op:"get_many" r)
      (pages W.bulk_keys_max keys)

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
      get_opt = get_opt t;
      get_range = get_range t;
      head_opt = head_opt t;
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
      verify_all = (fun _ -> `Unsupported);
      discard = (fun ~chunk_prefix:_ ~run:_ ~name:_ _ -> `Unsupported);
      capabilities = capabilities t;
      fast_read = false;
      local_path = None;
      health = t.health;
      traffic = Some t.traffic;
    }

let () =
  Tsync_store.Driver.register "http-proxy" { fields; linkless = false; create }
