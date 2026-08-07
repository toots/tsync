open Lwt.Syntax

let implementation = "http-proxy"

(* Nothing is locally cached from a proxy's point of view. *)
let is_local (_ : Conf.locality) _key = false

(* The login page for [/stats]. The report is server-rendered, so the page only
   signs a request and shows what comes back. *)
let stats_html = [%blob "stats.html"]

(* ponytail: plain ints touched only from the event-loop thread, so no locking —
   same reasoning as {!Metrics}. *)
let counters : (string, int) Hashtbl.t = Hashtbl.create 16
let in_flight = ref 0

(* How many requests may read or write object data at once.

   An inbound burst becomes that many concurrent reads of the backing storage,
   and the burst has no natural limit: one client opening one large file can ask
   for many ranges at once. Past what the device absorbs this is queueing, not
   throughput — a slow disk runs out of block-layer tags and the work already
   accepted finishes more slowly than if less had been.

   Metadata is outside the bound: a listing costs almost nothing and should not
   wait behind a transfer.

   ponytail: one global bound, not per-domain or per-client. The thing being
   protected is the storage under the process, which they all share. *)
let default_max_concurrent = 16

(* Slots for the work, plus a bounded queue for whoever cannot have one yet.

   An unbounded queue would turn a busy device into a growing list of promises
   and clients timing out with nothing to say why. Past the queue a caller is
   refused, which clients here read as backpressure: they retry 5xx with
   exponential backoff.

   Sized off the limit: enough to absorb a burst, small enough that sustained
   overload is refused rather than accumulated. *)
let gate : Lwt_bounded.t option ref = ref None
let make_gate limit = Lwt_bounded.create ~max:limit ~max_waiting:(limit * 16) ()

(* Published to clients so they hold their own excess. *)
let effective_max_concurrent : int option ref = ref None

let bounded op ~busy run =
  match (!gate, op) with
    | Some g, (`Get | `Put) -> Lwt_bounded.use_or g ~busy run
    | _ -> run ()

(* Smallest of the bounds the stores state. A store with no opinion is silent,
   not zero: object stores answer that way and must not drag the bound down. *)
let lowest answers =
  List.fold_left
    (fun acc n ->
      match (acc, n) with
        | Some a, Some b -> Some (min a b)
        | None, some | some, None -> some)
    None answers

let bump name =
  Hashtbl.replace counters name
    (1 + Option.value ~default:0 (Hashtbl.find_opt counters name))

let counters_json () =
  let held, waiting =
    match !gate with
      | Some g -> (Lwt_bounded.in_flight g, Lwt_bounded.waiting g)
      | None -> (0, 0)
  in
  `Assoc
    (("inFlight", `Int !in_flight)
     (* [dataWaiting] above zero means storage is the limit; [busy] climbing
       means the queue is overflowing. *)
    :: ("dataInFlight", `Int held)
    :: ("dataWaiting", `Int waiting)
    :: List.map
         (fun (k, v) -> (k, `Int v))
         (List.sort compare (List.of_seq (Hashtbl.to_seq counters))))

let opt (b : Frontend.binding) name = List.assoc_opt name b.Frontend.options
let nonempty = function Some "" | None -> None | Some s -> Some s

let distinct_values bindings name =
  List.sort_uniq compare
    (List.filter_map (fun b -> nonempty (opt b name)) bindings)

(* At most one distinct value across all bindings. *)
let listener_value bindings name =
  match distinct_values bindings name with
    | [] -> None
    | [v] -> Some v
    | _ ->
        failwith
          (Printf.sprintf
             "http-proxy: conflicting %s across domains sharing a port" name)

(* This binding's own value, else the single common one. *)
let inherited bindings b name =
  match nonempty (opt b name) with
    | Some v -> Some v
    | None -> (
        match distinct_values bindings name with [v] -> Some v | _ -> None)

type route = {
  domain_root : string;
  shares_prefix : string;
  secret : string;
  read_only : bool;
  chunk_size : int option;  (** what this domain's config says, if anything *)
  primary : (module Backend.S);
  all_backends : (module Backend.S) list;
  serve_share : share_handler option;
      (** [None] when this domain has no shares. *)
  socket_path : string;  (** the mount daemon's socket, if one runs here *)
  domain_name : string;
  self_frontend : Yojson.Safe.t;
      (** Per-domain settings only; shared process figures are reported once at
          the top. *)
  diagnose :
    totals:bool ->
    exact:bool ->
    reload:bool ->
    frontends:Yojson.Safe.t list ->
    Yojson.Safe.t Lwt.t;
      (** This domain's section of the status report. *)
}

(* Public share serving, when enabled for the domain. *)
and share_handler =
  token:string ->
  sub:string ->
  query:(string -> string option) ->
  range:string option ->
  (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t

let make_route bindings (b : Frontend.binding) =
  let module C = (val b.Frontend.conf : Conf.S) in
  let secret =
    match inherited bindings b "secret" with
      | Some s -> s
      | None ->
          failwith ("http-proxy: missing secret for domain " ^ C.domain_name)
  in
  (* [C.backends] is the role composite: [primary] resolves read fallbacks and
     backfill targets internally; writes fan out over [all_backends]. *)
  let serve_share =
    match inherited bindings b "shares" with
      | Some ("true" | "1") ->
          let module Sh = Share_server.Make (C) in
          Some
            (fun ~token ~sub ~query ~range ->
              Sh.handle ~token ~sub ~query ~range)
      | _ -> None
  in
  (* Serve-side write ban, independent of the domain's own [read_only]: it bars
     proxy clients while leaving this host's mount writable, and a client cannot
     opt out. Additive: a read-only domain is read-only over the proxy too. *)
  let read_only =
    C.read_only
    ||
      match inherited bindings b "readOnly" with
      | Some ("true" | "1") -> true
      | _ -> false
  in
  (* Secrets masked, as [tsync print-config] does: this gets pasted into bug
     reports. *)
  let options =
    List.map
      (fun (name, value) ->
        match
          List.find_opt
            (fun (s : Frontend.field_spec) -> s.name = name)
            (Frontend.spec_for implementation)
        with
          | Some { secret = true; _ } when value <> "" -> (name, `String "***")
          | _ -> (name, `String value))
      b.Frontend.options
  in
  let module Diag = Diagnostics.Make (C) in
  {
    domain_root = "tsync/" ^ C.domain_name ^ "/";
    shares_prefix = C.shares_prefix;
    secret;
    read_only;
    chunk_size = C.chunk_size;
    primary = List.hd C.backends;
    all_backends = C.backends;
    serve_share;
    socket_path = C.socket_path;
    domain_name = C.domain_name;
    self_frontend =
      `Assoc
        [
          ("type", `String implementation);
          (* The listener is shared, so it is reported once, at the top. *)
          ("shared", `Bool true);
          ("reachable", `Bool true);
          ("readOnly", `Bool read_only);
          ("shares", `Bool (serve_share <> None));
          ("options", `Assoc options);
        ];
    diagnose =
      (fun ~totals ~exact ~reload ~frontends ->
        Diag.domain_json ~totals ~exact ~reload ~frontends ());
  }

type op =
  | Get of string
  | Head of string
  | Put of string
  | Delete of string
  | Delete_multi of string list
  | Copy of string * string
  | List_all of string * int option
  | Share_url of string
  | Chunk_size of string
  | Max_concurrency of string
  | Bad
      (** One of ours but malformed: an undecodable key, a missing argument. *)
  | Unknown  (** not part of the API at all — a browser asking for a favicon *)

let parse_op meth uri body =
  let path = Uri.path uri in
  let obj_key () =
    match
      Http_proxy.Wire.decode_key (String.sub path 3 (String.length path - 3))
    with
      | Ok k -> Some k
      | Error _ -> None
  in
  let q name = Uri.get_query_param uri name in
  let is_obj p = String.starts_with ~prefix:"/o/" p in
  match (meth, path) with
    | `GET, p when is_obj p -> (
        match obj_key () with Some k -> Get k | None -> Bad)
    | `HEAD, p when is_obj p -> (
        match obj_key () with Some k -> Head k | None -> Bad)
    | `PUT, p when is_obj p -> (
        match obj_key () with Some k -> Put k | None -> Bad)
    | `DELETE, p when is_obj p -> (
        match obj_key () with Some k -> Delete k | None -> Bad)
    | `POST, "/delete-multi" -> (
        match try Some (Yojson.Safe.from_string body) with _ -> None with
          | Some (`List l) ->
              Delete_multi
                (List.filter_map (function `String x -> Some x | _ -> None) l)
          | _ -> Bad)
    | `POST, "/copy" -> (
        match (q "src", q "dst") with
          | Some src, Some dst -> Copy (src, dst)
          | _ -> Bad)
    | `GET, "/list" -> (
        match (q "mode", q "prefix") with
          | Some "all", Some prefix ->
              List_all (prefix, Option.bind (q "max_keys") int_of_string_opt)
          | _ -> Bad)
    | `GET, "/chunk-size" -> (
        match q "prefix" with Some prefix -> Chunk_size prefix | None -> Bad)
    | `GET, "/max-concurrency" -> (
        match q "prefix" with
          | Some prefix -> Max_concurrency prefix
          | None -> Bad)
    | `GET, "/share-url" -> (
        match q "prefix" with Some prefix -> Share_url prefix | None -> Bad)
    | _ -> Unknown

(* [Head] is metadata only; [Copy] is settled by the backend without the bytes
   passing through here. *)
let data_kind = function Get _ -> `Get | Put _ -> `Put | _ -> `Meta

let op_name = function
  | Get _ -> "get"
  | Head _ -> "head"
  | Put _ -> "put"
  | Delete _ -> "delete"
  | Delete_multi _ -> "deleteMulti"
  | Copy _ -> "copy"
  | List_all _ -> "list"
  | Share_url _ -> "shareUrl"
  | Chunk_size _ -> "chunkSize"
  | Max_concurrency _ -> "maxConcurrency"
  | Bad -> "badRequest"
  | Unknown -> "notFound"

(* A request targets the route whose [domain_root] prefixes its key. *)
let route_key = function
  | Get k | Head k | Put k | Delete k -> Some k
  | Delete_multi (k :: _) -> Some k
  | Delete_multi [] -> None
  | Copy (src, _) -> Some src
  | List_all (p, _) | Share_url p | Chunk_size p | Max_concurrency p -> Some p
  | Bad | Unknown -> None

let respond ?(status = `OK) ?(headers = []) body =
  Cohttp_lwt_unix.Server.respond_string ~status
    ~headers:(Cohttp.Header.of_list headers)
    ~body ()

let authed route req body =
  let meth = Cohttp.Code.string_of_method (Cohttp.Request.meth req) in
  let path = Uri.path_and_query (Cohttp.Request.uri req) in
  let h = Cohttp.Request.headers req in
  match
    ( Cohttp.Header.get h Http_proxy.Auth.timestamp_header,
      Cohttp.Header.get h Http_proxy.Auth.signature_header )
  with
    | Some timestamp, Some signature ->
        Http_proxy.Auth.verify ~secret:route.secret ~meth ~path ~timestamp
          ~signature ~body
    | _ -> false

let fanout route f = Lwt_list.iter_s (fun b -> f b) route.all_backends

let exec route op ~body =
  let reject_ro () = respond ~status:`Forbidden "read-only domain" in
  (* Share manifests live outside every domain root, so publishing or revoking a
     link changes no domain content. *)
  let writable key =
    (not route.read_only) || String.starts_with ~prefix:route.shares_prefix key
  in
  match op with
    | Get key -> (
        let module B = (val route.primary : Backend.S) in
        let* data = B.get_opt ~key () in
        match data with
          | Some data ->
              (* Once per request, not per backend a write fans out to: this is
                 the volume moved on a client's behalf. *)
              Metrics.add_downloaded (String.length data);
              respond data
          | None -> respond ~status:`Not_found "")
    | Head key -> (
        let module B = (val route.primary : Backend.S) in
        let* e = B.head_opt ~key () in
        match e with
          | Some e ->
              respond
                ~headers:
                  [
                    ("x-tsync-size", string_of_int e.Backend.size);
                    ( "x-tsync-last-modified",
                      Printf.sprintf "%f" e.Backend.last_modified );
                  ]
                ""
          | None -> respond ~status:`Not_found "")
    | Put key ->
        if not (writable key) then reject_ro ()
        else
          let* () =
            fanout route (fun (module B : Backend.S) ->
                B.put ~key ~data:body ())
          in
          Metrics.add_uploaded (String.length body);
          respond ""
    | Delete key ->
        if not (writable key) then reject_ro ()
        else
          let* () =
            fanout route (fun (module B : Backend.S) -> B.delete ~key ())
          in
          respond ""
    | Delete_multi keys ->
        if route.read_only then reject_ro ()
        else
          let* () =
            fanout route (fun (module B : Backend.S) -> B.delete_multi keys)
          in
          respond ""
    | Copy (src_key, dst_key) ->
        if route.read_only then reject_ro ()
        else
          let* () =
            fanout route (fun (module B : Backend.S) ->
                B.copy ~src_key ~dst_key ())
          in
          respond ""
    | List_all (prefix, max_keys) ->
        let module B = (val route.primary : Backend.S) in
        let* entries = B.list_prefix ?max_keys ~prefix () in
        respond (Http_proxy.Wire.entries_to_json entries)
    | Share_url prefix ->
        if route.serve_share <> None then
          (* The client composes the URL from the address it already reaches us
             on: TLS termination leaves us without a reliable view of our own
             public URL. *)
          respond (Yojson.Safe.to_string (`Assoc [("self", `Bool true)]))
        else (
          (* A backing store may serve shares itself (an s3 with a configured
             shareUrl): pass its absolute URL through. *)
          let rec find = function
            | [] -> respond ~status:`Not_found ""
            | (module B : Backend.S) :: rest -> (
                let* u = B.share_url ~prefix () in
                match u with
                  | Some url ->
                      respond
                        (Yojson.Safe.to_string (`Assoc [("url", `String url)]))
                  | None -> find rest)
          in
          find route.all_backends)
    | Chunk_size _ -> (
        (* So a client behind us writes new files at the size this domain already
           uses, instead of the setting living in both configs. Silence when
           unconfigured: the client's default matches what ours would be.
           ponytail: not chained through our own backends, so a proxy fronting a
           proxy answers only for itself. *)
          match route.chunk_size with
          | Some n ->
              respond (Yojson.Safe.to_string (`Assoc [("chunkSize", `Int n)]))
          | None -> respond ~status:`Not_found "")
    | Max_concurrency _ -> (
        (* Our effective bound — explicit setting or what our storage said — so a
           client in front of us holds its excess rather than parking it in our
           accept queue. Unlike the chunk size this is worth chaining: a proxy
           fronting a proxy is limited by whatever is furthest down. *)
          match !effective_max_concurrent with
          | Some n ->
              respond
                (Yojson.Safe.to_string (`Assoc [("maxConcurrency", `Int n)]))
          | None -> respond ~status:`Not_found "")
    | Bad | Unknown -> respond ~status:`Bad_request "bad request"

(* [shares_prefix] is domain-independent, so a share key has no domain to match
   on: fall back to the route whose secret signed the request.
   ponytail: the manifest then lands in that domain's store, which is what the
   share server reads as long as the fronted domains share one bucket. *)
let route_for routes ~key ~authed =
  match
    List.find_opt (fun r -> String.starts_with ~prefix:r.domain_root key) routes
  with
    | Some r -> Some r
    | None
      when List.exists
             (fun r -> String.starts_with ~prefix:r.shares_prefix key)
             routes ->
        List.find_opt authed routes
    | None -> None

(* Share links go to recipients holding no secret, so these routes carry no HMAC.
   The token is the only credential; {!Share_server.load} confines it to the
   shares prefix.
   ponytail: the first share-enabled domain answers — exact for a single-domain
   listener, and tokens are domain-independent anyway (shares_prefix is global);
   probe each domain here if one listener ever fronts several share stores. *)
let share_request routes uri =
  let path = Uri.path uri in
  if not (String.starts_with ~prefix:"/s/" path) then None
  else (
    match List.find_opt (fun r -> r.serve_share <> None) routes with
      | None -> None
      | Some r ->
          let rest = String.sub path 3 (String.length path - 3) in
          let token, sub =
            match String.index_opt rest '/' with
              | None -> (rest, "")
              | Some i ->
                  ( String.sub rest 0 i,
                    String.sub rest (i + 1) (String.length rest - i - 1) )
          in
          Some (Option.get r.serve_share, token, sub))

(* The mount daemon serving this domain on this host, when there is one.

   A domain's frontends are separate processes and {!Metrics} counts per process,
   so a mount's traffic is invisible here. On a host that both mounts and serves,
   reporting only our own would call a busy machine idle. Its transfer figures
   and process cost therefore come across too, attributed to it under the
   domain's [frontends] rather than added to ours. *)
let fetch_mount ~socket_path =
  let unreachable msg =
    `Assoc
      [
        ("reachable", `Bool false);
        ("socketPath", `String socket_path);
        ("error", `String msg);
      ]
  in
  Lwt.catch
    (fun () ->
      let request =
        Yojson.Safe.to_string (`Assoc [("action", `String "stats")])
      in
      let+ resp = Ipc.send_lwt ~socket_path request in
      let open Yojson.Safe.Util in
      let json = Yojson.Safe.from_string resp in
      let server = json |> member "server" in
      let proc = json |> member "process" in
      let carried =
        List.filter
          (fun (_, v) -> v <> `Null)
          [
            ("pid", server |> member "pid");
            ("uptimeSeconds", server |> member "uptimeSeconds");
            ("cpuSeconds", proc |> member "cpuSeconds");
            ("rssBytes", proc |> member "rssBytes");
            ("traffic", json |> member "traffic");
          ]
      in
      match json |> member "domains" with
        | `List (d :: _) -> (
            match d |> member "frontends" with
              | `List (`Assoc fields :: _) -> `Assoc (fields @ carried)
              | _ -> unreachable "daemon reported no frontend")
        | _ -> unreachable "daemon reported no domains")
    (fun exn ->
      Lwt.return
        (unreachable
           (match exn with
             | Lwt_unix.Timeout -> "timed out"
             | exn -> Printexc.to_string exn)))

(* One listener serves every domain configured on it, so its cpu, bytes and
   request counts cover all of them at once and belong to no single domain: they
   go in one labelled block at the top, and each domain lists only its own
   settings. *)
let status_json ~port ~tls ~totals ~exact ~reload routes =
  let+ domains =
    Lwt_list.map_p
      (fun route ->
        let* mount = fetch_mount ~socket_path:route.socket_path in
        route.diagnose ~totals ~exact ~reload
          ~frontends:[route.self_frontend; mount])
      routes
  in
  `Assoc
    (Diagnostics.self_json
       ~extra:
         [
           ("frontend", `String implementation);
           ("port", `Int port);
           ("tls", `Bool tls);
           ("serves", `List (List.map (fun r -> `String r.domain_name) routes));
           ("requests", counters_json ());
         ]
       ()
    @ [("domains", `List domains)])

(* Listener-wide, not domain-scoped, so any secret signing for this listener
   authorizes it: there is no key to route on. Text and JSON render the same
   collection, so a browser, [curl] and [tsync stats] cannot disagree. *)
let serve_status ~port ~tls ~json routes req body_str =
  if not (List.exists (fun r -> authed r req body_str) routes) then begin
    bump "unauthorized";
    respond ~status:`Unauthorized "unauthorized"
  end
  else begin
    bump "stats";
    (* [totals=1] estimates the chunk count from sampled shards; [totals=exact]
       counts every one, at the price of a full listing. Either is counted once
       and served from then on; [reload=1] asks for a new count. *)
    let param name = Uri.get_query_param (Cohttp.Request.uri req) name in
    let totals_param = param "totals" in
    let exact = totals_param = Some "exact" in
    let totals = exact || totals_param = Some "1" in
    let reload = totals && param "reload" = Some "1" in
    let* report = status_json ~port ~tls ~totals ~exact ~reload routes in
    if json then
      respond
        ~headers:[("content-type", "application/json")]
        (Yojson.Safe.to_string report)
    else
      respond
        ~headers:[("content-type", "text/plain; charset=utf-8")]
        (Diagnostics.text report)
  end

let callback ~port ~tls routes _conn req body =
  let meth = Cohttp.Request.meth req in
  let uri = Cohttp.Request.uri req in
  match share_request routes uri with
    | Some (handle, token, sub) ->
        bump "share";
        handle ~token ~sub ~query:(Uri.get_query_param uri)
          ~range:(Cohttp.Header.get (Cohttp.Request.headers req) "range")
    | None -> (
        let* body_str = Cohttp_lwt.Body.to_string body in
        match (meth, Uri.path uri) with
          | `GET, ("/" | "/index.html") ->
              bump "page";
              respond
                ~headers:[("content-type", "text/html; charset=utf-8")]
                stats_html
          | `GET, "/stats" ->
              serve_status ~port ~tls ~json:false routes req body_str
          | `GET, "/api/v1/stats" ->
              serve_status ~port ~tls ~json:true routes req body_str
          | _ -> (
              let op = parse_op meth uri body_str in
              match route_key op with
                (* A path outside the API is a 404; [badRequest] is reserved for
                   a call that aimed at this API and got it wrong. *)
                | None when op = Unknown ->
                    bump "notFound";
                    respond ~status:`Not_found "not found"
                | None ->
                    bump "badRequest";
                    respond ~status:`Bad_request "bad request"
                | Some key -> (
                    match
                      route_for routes ~key ~authed:(fun r ->
                          authed r req body_str)
                    with
                      | None -> respond ~status:`Not_found "unknown domain"
                      | Some route ->
                          if not (authed route req body_str) then begin
                            bump "unauthorized";
                            respond ~status:`Unauthorized "unauthorized"
                          end
                          else begin
                            bump (op_name op);
                            incr in_flight;
                            Lwt.finalize
                              (fun () ->
                                Lwt.catch
                                  (fun () ->
                                    bounded (data_kind op)
                                      ~busy:(fun () ->
                                        (* Refused, not failed: the client backs
                                           off. *)
                                        bump "busy";
                                        respond ~status:`Service_unavailable
                                          "busy")
                                      (fun () -> exec route op ~body:body_str))
                                  (fun exn ->
                                    bump "error";
                                    Log.err "http-proxy: %s"
                                      (Printexc.to_string exn);
                                    respond ~status:`Internal_server_error
                                      (Printexc.to_string exn)))
                              (fun () ->
                                decr in_flight;
                                Lwt.return_unit)
                          end)))

let start bindings =
  (* Post-fork leaf process: safe to initialize Lwt now. *)
  Frontend.cap_blocking_pool ();
  (Lwt.async_exception_hook :=
     fun exn ->
       Log.err "http-proxy async exception: %s" (Printexc.to_string exn));
  let cert = listener_value bindings "ssl_certificate" in
  let key = listener_value bindings "ssl_certificate_key" in
  (match (cert, key) with
    | Some _, Some _ | None, None -> ()
    | _ ->
        failwith
          "http-proxy: ssl_certificate and ssl_certificate_key must both be set");
  let tls = cert <> None in
  let port =
    match listener_value bindings "port" with
      | Some p -> int_of_string p
      | None -> if tls then 443 else 80
  in
  let configured_max_concurrent =
    match listener_value bindings "max_concurrent" with
      | Some v -> (
          match int_of_string_opt v with
            | Some n when n > 0 -> Some n
            | _ ->
                failwith "http-proxy: max_concurrent must be a positive integer"
          )
      | None -> None
  in
  let routes = List.map (make_route bindings) bindings in
  let mode =
    match (cert, key) with
      | Some c, Some k ->
          `TLS (`Crt_file_path c, `Key_file_path k, `No_password, `Port port)
      | _ -> `TCP (`Port port)
  in
  Log.info "http-proxy listening on port %d (%s), %d domains" port
    (if tls then "https" else "http")
    (List.length routes);
  Lwt_main.run
    (let open Lwt.Syntax in
     (* No IPC socket, so [tsync stop] never reaches this frontend and a signal
        is the only way it is asked to stop. It serves writes for proxy clients,
        so the default action would drop what those still owe a backfill
        target. *)
     let stop, wake = Lwt.wait () in
     let request_stop () =
       match Lwt.state stop with
         | Lwt.Sleep -> Lwt.wakeup_later wake ()
         | _ -> ()
     in
     List.iter
       (fun s -> ignore (Lwt_unix.on_signal s (fun _ -> request_stop ())))
       [Sys.sigterm; Sys.sigint];
     (* An explicit setting wins: it knows things about the deployment a probe
        cannot see. Otherwise take the storage's lowest answer — a bound ignoring
        the slowest participant is not a bound. With no opinion anywhere (every
        purely network-backed domain), fall back to a figure that only exists to
        stop an unbounded pile-up. *)
     let* derived =
       match configured_max_concurrent with
         | Some _ -> Lwt.return_none
         | None ->
             let backends = List.concat_map (fun r -> r.all_backends) routes in
             let+ answers =
               Lwt_list.map_s
                 (fun (module B : Backend.S) ->
                   Lwt.catch
                     (fun () -> B.max_concurrency ~prefix:"" ())
                     (fun _ -> Lwt.return_none))
                 backends
             in
             lowest answers
     in
     let max_concurrent =
       match (configured_max_concurrent, derived) with
         | Some n, _ -> n
         | None, Some n -> n
         | None, None -> default_max_concurrent
     in
     Log.info "http-proxy serving at most %d object reads/writes at once (%s)"
       max_concurrent
       (match (configured_max_concurrent, derived) with
         | Some _, _ -> "configured"
         | None, Some _ -> "from the storage"
         | None, None -> "default");
     gate := Some (make_gate max_concurrent);
     (* The gate holds callers at the door; this keeps the threads behind it from
        outnumbering what the device takes. Narrowed only when the storage said
        something: a purely network-backed domain keeps the generous default. *)
       (match derived with
       | Some n -> Frontend.size_blocking_pool ~concurrency:n
       | None -> ());
     effective_max_concurrent := Some max_concurrent;
     let* () =
       Cohttp_lwt_unix.Server.create ~stop ~mode
         (Cohttp_lwt_unix.Server.make ~callback:(callback ~port ~tls routes) ())
     in
     Log.info "http-proxy stopping, letting backends catch up";
     Backend.drain ())

let spec =
  Frontend.
    [
      {
        name = "port";
        label = "Listen port (default: 443 with TLS, else 80)";
        typ = `Int;
        default = Some "";
        secret = false;
      };
      {
        name = "max_concurrent";
        label =
          Printf.sprintf
            "Object reads/writes served at once, over which requests queue \
             (default: %d)"
            default_max_concurrent;
        typ = `Int;
        default = Some "";
        secret = false;
      };
      {
        name = "secret";
        label = "Shared HMAC secret (clients must match)";
        typ = `String;
        default = Some "";
        secret = true;
      };
      {
        name = "shares";
        label = "Serve public share links on /s/";
        typ = `Bool;
        default = Some "false";
        secret = false;
      };
      {
        name = "readOnly";
        label = "Refuse writes from proxy clients (local mount unaffected)";
        typ = `Bool;
        default = Some "false";
        secret = false;
      };
      {
        name = "ssl_certificate";
        label = "TLS certificate path (blank = plain HTTP)";
        typ = `String;
        default = Some "";
        secret = false;
      };
      {
        name = "ssl_certificate_key";
        label = "TLS private key path";
        typ = `String;
        default = Some "";
        secret = false;
      };
    ]

let () =
  Frontend.register ~spec implementation
    (module struct
      let is_local = is_local
      let start = start
    end : Frontend.S)
