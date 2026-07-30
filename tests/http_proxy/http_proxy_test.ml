(* ── Fixture for the status endpoints ─────────────────────────────────────── *)

let status_root = "/tmp/tsync-http-proxy-status-test"

module C : Conf.S = struct
  let versioning = false
  let client_name = "test-client"
  let domain_name = "statusdom"
  let domain_prefix = "tsync/statusdom/manifests/"
  let chunk_prefix = "tsync/statusdom/chunks/"
  let versions_prefix = "tsync/statusdom/versions/"
  let journal_prefix = "tsync/statusdom/journal/"
  let cursor_key = "tsync/statusdom/cursor"
  let shares_prefix = "tsync/shares/"
  let backends = [Local_backend.make ~root:(status_root ^ "/store")]
  let cache_root = status_root ^ "/cache"
  let data_dir = status_root ^ "/data"

  (* Nothing listens here: the report must say the mount is unreachable rather
     than wait on it. *)
  let socket_path = status_root ^ "/absent.sock"
  let notify_path = ""
  let max_uploads = 2
  let max_downloads = 3
  let chunk_size = Some 65536
  let cache_chunk_size = Some 65536
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

(* A store that cannot be reached, so the report has a failure to point at. *)
module Down : Backend.S = struct
  let fail () = Lwt.fail (Backend.Backend_error "connection refused")
  let put ~key:_ ~data:_ () = fail ()
  let get ~key:_ () = fail ()
  let get_opt ~key:_ () = fail ()
  let head_opt ~key:_ () = fail ()
  let delete ~key:_ () = fail ()
  let delete_multi _ = fail ()
  let copy ~src_key:_ ~dst_key:_ () = fail ()
  let list_prefix ?max_keys:_ ~prefix:_ () = fail ()
  let share_url ~prefix:_ () = Lwt.return_none
  let default_chunk_size ~prefix:_ () = Lwt.return_none
end

let json_member name j = Yojson.Safe.Util.member name j

(* Everything in the report that moves between runs, pinned to a fixed value of
   the same type — so the snapshot below reviews the shape and the wording while
   staying readable as a real report. Rates are timing-dependent (a rolling window
   over wall-clock seconds), hence pinned too; the mount snapshot exercises rate
   rendering with literals instead. *)
let stable_values =
  [
    ("hostname", `String "testhost");
    ("pid", `Int 1234);
    ("startedAt", `Float 1700000000.);
    ("uptimeSeconds", `Float 3600.);
    ("cpuSeconds", `Float 12.5);
    ("cpuPercentAvg", `Float 0.3);
    ("rssBytes", `Int 41943040);
    ("heapBytes", `Int 8388608);
    ("topHeapBytes", `Int 12582912);
    ("minorCollections", `Int 100);
    ("majorCollections", `Int 10);
    ("readableFds", `Int 2);
    ("writableFds", `Int 0);
    ("timers", `Int 0);
    ("latencyMs", `Float 1.);
    ("bytesUploaded", `Int 4096);
    ("bytesDownloaded", `Int 2048);
    ("uploadBytesPerSec", `Int 0);
    ("downloadBytesPerSec", `Int 0);
    ("hashesPerSec", `Int 0);
    (* recentErrors entries: the message text is stable, the time is not. *)
    ("t", `Float 1700000000.);
    (* Whatever this machine happens to have free. *)
    ("availableBytes", `Int 107374182400);
    ("totalBytes", `Int 494384795648);
    ("sampledSecondsAgo", `Int 0);
  ]

(* Replace every present field named in [values], at any depth. Used both to pin
   the moving parts and to drop a mount daemon into an otherwise real report. *)
let rec substitute ~values (j : Yojson.Safe.t) =
  match j with
    | `Assoc fields ->
        `Assoc
          (List.map
             (fun (k, v) ->
               match List.assoc_opt k values with
                 | Some fixed when v <> `Null -> (k, fixed)
                 | _ -> (k, substitute ~values v))
             fields)
    | `List l -> `List (List.map (substitute ~values) l)
    | v -> v

let signed_request ~secret ~path =
  let headers =
    Http_proxy.Auth.request_headers ~secret ~meth:"GET" ~path ~body:""
  in
  Cohttp.Request.make
    ~headers:(Cohttp.Header.of_list headers)
    (Uri.of_string path)

let status_code resp = Cohttp.Code.code_of_status (Cohttp.Response.status resp)

let content_type resp =
  Option.value ~default:""
    (Cohttp.Header.get (Cohttp.Response.headers resp) "content-type")

let () =
  let secret = "s3cr3t"
  and meth = "GET"
  and path = "/o/abc"
  and body = "hello" in
  (* A freshly-signed request verifies. *)
  let headers = Http_proxy.Auth.request_headers ~secret ~meth ~path ~body in
  let ts = List.assoc Http_proxy.Auth.timestamp_header headers in
  let sig_ = List.assoc Http_proxy.Auth.signature_header headers in
  assert (
    Http_proxy.Auth.verify ~secret ~meth ~path ~timestamp:ts ~signature:sig_
      ~body);

  (* Wrong secret, tampered path, tampered body, and bad signature all fail. *)
  assert (
    not
      (Http_proxy.Auth.verify ~secret:"other" ~meth ~path ~timestamp:ts
         ~signature:sig_ ~body));
  assert (
    not
      (Http_proxy.Auth.verify ~secret ~meth ~path:"/o/xyz" ~timestamp:ts
         ~signature:sig_ ~body));
  assert (
    not
      (Http_proxy.Auth.verify ~secret ~meth ~path ~timestamp:ts ~signature:sig_
         ~body:"tampered"));
  assert (
    not
      (Http_proxy.Auth.verify ~secret ~meth ~path ~timestamp:ts
         ~signature:"deadbeef" ~body));

  (* A stale timestamp (outside the skew window) fails. *)
  let old_ts = Printf.sprintf "%.0f" (Unix.time () -. 1000.) in
  let old_sig =
    Http_proxy.Auth.sign ~secret ~meth ~path ~timestamp:old_ts ~body
  in
  assert (
    not
      (Http_proxy.Auth.verify ~secret ~meth ~path ~timestamp:old_ts
         ~signature:old_sig ~body));

  (* Key encoding round-trips (keys carry '/', '-', hex). *)
  let key = "tsync/Romain's Files/chunks/9af3-2b1c" in
  assert (Http_proxy.Wire.decode_key (Http_proxy.Wire.encode_key key) = Ok key);

  (* file_entry JSON round-trips. *)
  let entries =
    [
      { Backend.key = "a"; size = 3; last_modified = 1.5 };
      { Backend.key = "b/c"; size = 0; last_modified = 0. };
    ]
  in
  assert (
    Http_proxy.Wire.entries_of_json (Http_proxy.Wire.entries_to_json entries)
    = entries);

  (* Routing: domain keys go to their domain; share manifests (which sit outside
     every domain root) go to the route whose secret signed the request. *)
  let route name =
    {
      Http_proxy_frontend.domain_root = "tsync/" ^ name ^ "/";
      shares_prefix = "tsync/shares/";
      secret = name;
      read_only = false;
      chunk_size = None;
      primary = Local_backend.make ~root:"/tmp/tsync-route-test";
      all_backends = [];
      serve_share = None;
      socket_path = "/nonexistent/tsync.sock";
      domain_name = "one";
      self_frontend = `Assoc [];
      diagnose = (fun ~totals:_ ~frontends:_ -> Lwt.return (`Assoc []));
    }
  in
  let routes = [route "one"; route "two"] in
  let pick key signer =
    Option.map
      (fun r -> r.Http_proxy_frontend.secret)
      (Http_proxy_frontend.route_for routes ~key ~authed:(fun r ->
           r.Http_proxy_frontend.secret = signer))
  in
  (* The chunk-size question is a domain-scoped GET like any other, so it routes
     by prefix: a client behind the proxy asks the domain it is talking to. *)
  let chunk_size_op prefix =
    Http_proxy_frontend.parse_op `GET
      (Uri.of_string ("/chunk-size?prefix=" ^ prefix))
      ""
  in
  assert (
    chunk_size_op "tsync/one/" = Http_proxy_frontend.Chunk_size "tsync/one/");
  assert (
    Http_proxy_frontend.route_key (chunk_size_op "tsync/one/")
    = Some "tsync/one/");
  (* No prefix is a bad request, not a silent answer for some other domain. *)
  assert (
    Http_proxy_frontend.parse_op `GET (Uri.of_string "/chunk-size") ""
    = Http_proxy_frontend.Bad);

  assert (pick "tsync/two/manifests/x" "one" = Some "two");
  assert (pick "tsync/shares/deadbeef" "two" = Some "two");
  assert (pick "tsync/shares/deadbeef" "nobody" = None);
  assert (pick "elsewhere/x" "one" = None);

  (* Specs are what [tsync configure] prompts from, so a field missing here is
     silently unconfigurable. [shares] is declared on the frontend only: the
     client asks the proxy over /share-url rather than mirroring the setting,
     so a second copy in backend config could only drift out of agreement. *)
  let has_field name specs =
    List.exists (fun (s : Backend.field_spec) -> s.name = name) specs
  in
  let backend_spec =
    match Backend.spec_for "http-proxy" with
      | Some s -> s
      | None -> failwith "http-proxy backend not registered"
  in
  assert (has_field "url" backend_spec);
  assert (has_field "secret" backend_spec);
  assert (not (has_field "shares" backend_spec));
  let frontend_spec = Frontend.spec_for "http-proxy" in
  let has_frontend_field name =
    List.exists (fun (s : Frontend.field_spec) -> s.name = name) frontend_spec
  in
  assert (has_frontend_field "shares");
  assert (has_frontend_field "readOnly");

  (* A read-only route refuses every mutating op and still answers reads, so a
     client cannot write through the proxy whatever its own config says. *)
  let status op ~read_only =
    let r = { (route "one") with read_only } in
    let resp, _ = Lwt_main.run (Http_proxy_frontend.exec r op ~body:"x") in
    Cohttp.Code.code_of_status (Cohttp.Response.status resp)
  in
  let key = "tsync/one/manifests/x" in
  List.iter
    (fun op -> assert (status op ~read_only:true = 403))
    [
      Http_proxy_frontend.Put key;
      Http_proxy_frontend.Delete key;
      Http_proxy_frontend.Delete_multi [key];
      Http_proxy_frontend.Copy (key, key ^ "2");
    ];
  (* Reads are unaffected: absent key, not forbidden. *)
  assert (status (Http_proxy_frontend.Get key) ~read_only:true = 404);
  (* And the same writes are permitted when the route is writable. *)
  assert (status (Http_proxy_frontend.Put key) ~read_only:false = 200);

  (* Sharing keeps working on a read-only domain: a share manifest lives outside
     the domain root and publishing one changes no content. Revoking likewise. *)
  let share_key = "tsync/shares/deadbeef" in
  assert (status (Http_proxy_frontend.Put share_key) ~read_only:true = 200);
  assert (status (Http_proxy_frontend.Delete share_key) ~read_only:true = 200);

  (* ── Status endpoints ───────────────────────────────────────────────────── *)

  (* The store directory has to exist for its filesystem to be measurable — a
     capacity of "unknown" is what an absent path correctly reports. *)
  Lwt_main.run (Fs_util.mkdir_p (status_root ^ "/store"));

  (* Two stores, one of them down, so the report has to name which. *)
  Backend.report_members ~domain:C.domain_name
    [
      {
        Backend.name = "disk";
        role = "main";
        backend_type = "local";
        config = [("path", status_root ^ "/store")];
        backend = List.hd C.backends;
        pending = None;
        in_flight = None;
        degraded = None;
        (* A real path, so the capacity line is exercised — its numbers are
           whatever this machine has, hence pinned in the snapshot. *)
        local_path = Some (status_root ^ "/store");
      };
      {
        Backend.name = "archive";
        role = "backfill";
        backend_type = "http-proxy";
        (* A remote store, so the report has to say where it points — and the
           secret must not be what it says. *)
        config = [("url", "https://nas.example:8443"); ("secret", "***")];
        backend = (module Down);
        pending = Some (fun () -> 7);
        in_flight = Some (fun () -> 2);
        degraded = Some (fun () -> true);
        local_path = None;
      };
    ];
  (* Through [make_route], so option masking and the diagnose wiring are the real
     ones rather than a stand-in. *)
  let binding =
    {
      Frontend.conf = (module C : Conf.S);
      options = [("port", "8443"); ("secret", "s3cr3t")];
      mount_point = "";
    }
  in
  let status_routes = [Http_proxy_frontend.make_route [binding] binding] in
  let report ?(totals = false) () =
    Lwt_main.run
      (Http_proxy_frontend.status_json ~port:8443 ~tls:true ~totals
         status_routes)
  in
  let r = report () in
  List.iter
    (fun key -> assert (json_member key r <> `Null))
    ["server"; "process"; "lwt"; "traffic"; "recentErrors"; "domains"];
  (* The answering process says which frontend it is and which domains that
     covers: a shared listener's cpu and counters belong to all of them, so they
     are reported here and not filed under one domain. *)
  let server = json_member "server" r in
  assert (json_member "frontend" server = `String "http-proxy");
  assert (json_member "serves" server = `List [`String "statusdom"]);
  assert (json_member "requests" server <> `Null);
  let domain =
    match json_member "domains" r with
      | `List [d] -> d
      | _ -> failwith "expected exactly one domain"
  in
  assert (json_member "name" domain = `String "statusdom");
  assert (json_member "clientName" domain = `String "test-client");
  (* Config as this process resolved it, not as a file spells it. *)
  assert (json_member "maxDownloads" domain = `Int 3);
  (* The listener appears as one of the domain's frontends, carrying the settings
     that are this domain's — the shared process figures being reported once, at
     the top. *)
  let frontends =
    match json_member "frontends" domain with `List l -> l | _ -> []
  in
  let proxy_frontend =
    List.find (fun f -> json_member "type" f = `String "http-proxy") frontends
  in
  assert (json_member "shared" proxy_frontend = `Bool true);
  (* The shared secret must not leave the process, even to an authorized caller:
     a report gets pasted into bug threads. *)
  let options = json_member "options" proxy_frontend in
  assert (json_member "secret" options = `String "***");
  assert (json_member "port" options = `String "8443");
  (* Nothing listens on the socket, so the other frontend is reported as not
     answering — named by the socket it was asked on — rather than awaited. *)
  let mount_frontend =
    List.find (fun f -> json_member "type" f <> `String "http-proxy") frontends
  in
  assert (json_member "reachable" mount_frontend = `Bool false);
  assert (json_member "socketPath" mount_frontend <> `Null);
  let backends =
    match json_member "backends" domain with `List l -> l | _ -> []
  in
  assert (List.length backends = 2);
  let by_name name =
    List.find (fun b -> json_member "name" b = `String name) backends
  in
  assert (json_member "role" (by_name "disk") = `String "main");
  assert (json_member "reachable" (by_name "disk") = `Bool true);
  let archive = by_name "archive" in
  assert (json_member "reachable" archive = `Bool false);
  assert (json_member "error" archive <> `Null);
  let backfill = json_member "backfill" archive in
  assert (json_member "queued" backfill = `Int 7);
  assert (json_member "degraded" backfill = `Bool true);

  (* Counting what a store holds is opt-in, and never done while a request waits:
     the first ask starts a walk in the background and says so, a later one has the
     numbers. A status endpoint must not block on enumerating a large store. *)
  assert (json_member "totals" (by_name "disk") = `Null);
  let disk_totals report =
    match json_member "domains" report with
      | `List [d] -> (
          match json_member "backends" d with
            | `List l ->
                json_member "totals"
                  (List.find (fun b -> json_member "name" b = `String "disk") l)
            | _ -> `Null)
      | _ -> `Null
  in
  assert (
    json_member "counting" (disk_totals (report ~totals:true ())) = `Bool true);
  (* Let the background walk land. Bounded retry rather than a fixed sleep: the
     walk is over an empty store, so this is one iteration in practice. *)
  let rec await_counts tries =
    let t = disk_totals (report ~totals:true ()) in
    if json_member "chunks" t <> `Null then t
    else if tries = 0 then failwith "counts never arrived"
    else begin
      Lwt_main.run (Lwt_unix.sleep 0.05);
      await_counts (tries - 1)
    end
  in
  let counted = await_counts 40 in
  assert (json_member "chunks" counted <> `Null);
  assert (json_member "sampledSecondsAgo" counted <> `Null);

  (* Both representations are snapshotted below, which is where the shape is
     actually reviewed. This one stays an assertion because a snapshot can be
     promoted without being read, and a leaked shared secret must not be able to
     ride in on a promote. *)
  assert (
    json_member "secret" (json_member "options" proxy_frontend) = `String "***");
  (* The same rule for a backend that points at a remote server. *)
  assert (
    json_member "secret" (json_member "config" (by_name "archive"))
    = `String "***");

  (* A domain's frontends are separate processes with separate counters, so the
     bytes a mount moves are invisible to the proxy's own metrics. They are carried
     over IPC and reported as that frontend's own — a page showing only its own
     zero would say "no traffic" about a busy machine. Shaped as the daemon
     actually answers. *)
  let mount_fixture =
    `Assoc
      [
        ("type", `String "fuse");
        ("reachable", `Bool true);
        ("mountPoint", `String "/home/u/tsync/statusdom");
        ("stagedFiles", `Int 0);
        ("pendingUploads", `Int 2);
        ("openHandles", `Int 3);
        ("filesOpened", `Int 41);
        ("bytesRead", `Int 2147483648);
        ("bytesWritten", `Int 0);
        ("bytesReadPerSec", `Int 5242880);
        ("bytesWrittenPerSec", `Int 0);
        ("pid", `Int 18103);
        ("uptimeSeconds", `Float 3600.);
        ("cpuSeconds", `Float 35.5);
        ("rssBytes", `Int 57638912);
        ( "traffic",
          `Assoc
            [
              ("bytesUploaded", `Int 0);
              ("bytesDownloaded", `Int 788029143);
              ("uploadBytesPerSec", `Int 0);
              ("downloadBytesPerSec", `Int 1048576);
              ("chunksHashed", `Int 0);
              ("hashesPerSec", `Int 0);
            ] );
      ]
  in

  (* Both routes verify the same HMAC as the object API, and neither answers
     without one. *)
  let serve ~json req =
    let resp, _ =
      Lwt_main.run
        (Http_proxy_frontend.serve_status ~port:8443 ~tls:true ~json
           status_routes req "")
    in
    (status_code resp, content_type resp)
  in
  assert (
    fst (serve ~json:false (Cohttp.Request.make (Uri.of_string "/stats"))) = 401);
  assert (
    serve ~json:false (signed_request ~secret:"s3cr3t" ~path:"/stats")
    = (200, "text/plain; charset=utf-8"));
  assert (
    serve ~json:true (signed_request ~secret:"s3cr3t" ~path:"/api/v1/stats")
    = (200, "application/json"));
  (* A wrong secret is refused. *)
  assert (
    fst
      (serve ~json:true (signed_request ~secret:"wrong" ~path:"/api/v1/stats"))
    = 401);

  (* Serving those requests is itself counted, refusals included. *)
  let counters = Http_proxy_frontend.counters_json () in
  assert (json_member "stats" counters = `Int 2);
  assert (json_member "unauthorized" counters = `Int 2);

  (* ── Snapshots ──────────────────────────────────────────────────────────────
     The two representations side by side, which is the point: /api/v1/stats and
     /stats are one collection rendered twice, and a diff here is the review of
     both. The JSON keeps raw counts; only the text spells sizes for a person. *)
  let stable = substitute ~values:stable_values r in
  print_endline "########## /api/v1/stats ##########";
  print_endline (Yojson.Safe.pretty_to_string stable);
  print_endline "########## /stats ##########";
  print_string (Diagnostics.text stable);
  (* The same report on a host that also mounts the domain. *)
  print_endline "########## /stats with a mount daemon ##########";
  print_string
    (Diagnostics.text
       (substitute
          ~values:
            [
              ( "frontends",
                `List
                  [
                    `Assoc
                      [
                        ("type", `String "http-proxy");
                        ("shared", `Bool true);
                        ("reachable", `Bool true);
                        ("readOnly", `Bool false);
                        ("shares", `Bool false);
                        ("options", `Assoc [("port", `String "8443")]);
                      ];
                    mount_fixture;
                  ] );
            ]
          stable));
  print_endline "http_proxy_test ok"
