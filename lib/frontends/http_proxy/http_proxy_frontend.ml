open Lwt.Syntax

let implementation = "http-proxy"

(* The proxy is not a local mount; nothing is "locally cached" from its point of
   view. *)
let is_local ~cache_root:_ ~domain_name:_ ~domain_prefix:_ _key = false

(* ── Option resolution (with inheritance across the shared listener) ─────────── *)

let opt (b : Frontend.binding) name = List.assoc_opt name b.Frontend.options
let nonempty = function Some "" | None -> None | Some s -> Some s

let distinct_values bindings name =
  List.sort_uniq compare
    (List.filter_map (fun b -> nonempty (opt b name)) bindings)

(* A listener-scoped option: at most one distinct value across all bindings. *)
let listener_value bindings name =
  match distinct_values bindings name with
    | [] -> None
    | [v] -> Some v
    | _ ->
        failwith
          (Printf.sprintf
             "http-proxy: conflicting %s across domains sharing a port" name)

(* A per-domain option: this binding's own value, else the single common value. *)
let inherited bindings b name =
  match nonempty (opt b name) with
    | Some v -> Some v
    | None -> (
        match distinct_values bindings name with [v] -> Some v | _ -> None)

(* ── Routing table ──────────────────────────────────────────────────────────── *)

type route = {
  domain_root : string;
  secret : string;
  read_only : bool;
  primary : (module Backend.S);
  all_backends : (module Backend.S) list;
}

let make_route bindings (b : Frontend.binding) =
  let module C = (val b.Frontend.conf : Conf.S) in
  let secret =
    match inherited bindings b "secret" with
      | Some s -> s
      | None ->
          failwith ("http-proxy: missing secret for domain " ^ C.domain_name)
  in
  (* [C.backends] is the (possibly tiered) backend set: [primary] tiers reads/
     backfill internally, and writes fan out over [all_backends]. *)
  {
    domain_root = "tsync/" ^ C.domain_name ^ "/";
    secret;
    read_only = C.read_only;
    primary = List.hd C.backends;
    all_backends = C.backends;
  }

(* ── Request handling ───────────────────────────────────────────────────────── *)

type op =
  | Get of string
  | Head of string
  | Put of string
  | Delete of string
  | Delete_multi of string list
  | Copy of string * string
  | List_all of string * int option
  | List_dir of string
  | Share_url of string
  | Bad

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
          | Some "dir", Some prefix -> List_dir prefix
          | _ -> Bad)
    | `GET, "/share-url" -> (
        match q "prefix" with Some prefix -> Share_url prefix | None -> Bad)
    | _ -> Bad

(* The domain a request targets is the route whose [domain_root] prefixes the
   operation's key/prefix. *)
let route_key = function
  | Get k | Head k | Put k | Delete k -> Some k
  | Delete_multi (k :: _) -> Some k
  | Delete_multi [] -> None
  | Copy (src, _) -> Some src
  | List_all (p, _) | List_dir p | Share_url p -> Some p
  | Bad -> None

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
  match op with
    | Get key -> (
        let module B = (val route.primary : Backend.S) in
        let* data = B.get_opt ~key () in
        match data with
          | Some data -> respond data
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
        if route.read_only then reject_ro ()
        else
          let* () =
            fanout route (fun (module B : Backend.S) ->
                B.put ~key ~data:body ())
          in
          respond ""
    | Delete key ->
        if route.read_only then reject_ro ()
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
        let* entries = B.list_all ?max_keys ~prefix () in
        respond (Http_proxy.Wire.entries_to_json entries)
    | List_dir prefix ->
        let module B = (val route.primary : Backend.S) in
        let* result = B.list_directory ~prefix () in
        respond (Http_proxy.Wire.list_dir_to_json result)
    | Share_url prefix ->
        (* The first of this domain's backends that serves shares. *)
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
        find route.all_backends
    | Bad -> respond ~status:`Bad_request "bad request"

let callback routes _conn req body =
  let meth = Cohttp.Request.meth req in
  let uri = Cohttp.Request.uri req in
  let* body_str = Cohttp_lwt.Body.to_string body in
  let op = parse_op meth uri body_str in
  match route_key op with
    | None -> respond ~status:`Bad_request "bad request"
    | Some key -> (
        match
          List.find_opt
            (fun r -> String.starts_with ~prefix:r.domain_root key)
            routes
        with
          | None -> respond ~status:`Not_found "unknown domain"
          | Some route ->
              if not (authed route req body_str) then
                respond ~status:`Unauthorized "unauthorized"
              else
                Lwt.catch
                  (fun () -> exec route op ~body:body_str)
                  (fun exn ->
                    Log.err "http-proxy: %s" (Printexc.to_string exn);
                    respond ~status:`Internal_server_error
                      (Printexc.to_string exn)))

(* ── Listener ───────────────────────────────────────────────────────────────── *)

let start bindings =
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
    (Cohttp_lwt_unix.Server.create ~mode
       (Cohttp_lwt_unix.Server.make ~callback:(callback routes) ()))

let register () =
  Frontend.register implementation
    (module struct
      let is_local = is_local
      let start = start
    end : Frontend.S)
