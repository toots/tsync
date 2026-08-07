let status_root = "/tmp/tsync-http-proxy-status-test"

module Down : Backend.S = struct
  let fail () = Lwt.fail (Backend.Backend_error "connection refused")
  let put ~key:_ ~data:_ () = fail ()
  let put_if_absent ~key:_ ~data:_ () = fail ()
  let get ~key:_ () = fail ()
  let get_opt ~key:_ () = fail ()
  let head_opt ~key:_ () = fail ()
  let delete ~key:_ () = fail ()
  let delete_multi _ = fail ()
  let copy ~src_key:_ ~dst_key:_ () = fail ()
  let list_prefix ?max_keys:_ ~prefix:_ () = fail ()
  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
end

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
  let store = Local_backend.make ~root:(status_root ^ "/store")

  (* Two stores, one of them down, so the report has to name which. *)
  let members =
    [
      Backend.member ~name:"disk"
        ~config:[("path", status_root ^ "/store")]
          (* A real path, so the capacity line is exercised — its numbers are
             whatever this machine has, hence pinned in the snapshot. *)
        ~local_path:(status_root ^ "/store") store;
      Backend.member ~name:"archive" ~role:"backfill" ~readable:false
        ~backend_type:"http-proxy"
          (* A remote store, so the report has to say where it points — and the
             secret must not be what it says. *)
        ~config:[("url", "https://nas.example:8443"); ("secret", "***")]
        ~pending:(fun () -> 7)
        ~in_flight:(fun () -> 2)
        ~degraded:(fun () -> true)
        (module Down);
    ]

  let cache_root = status_root ^ "/cache"
  let data_dir = status_root ^ "/data"

  (* Nothing listens here: the report must say the mount is unreachable rather
     than wait on it. *)
  let socket_path = status_root ^ "/absent.sock"
  let max_uploads = 2
  let max_chunk_buffers = 2
  let max_downloads = 3
  let chunk_size = Some 65536
  let cache_chunk_size = Some 65536
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

(* A store that cannot be reached, so the report has a failure to point at. *)

let json_member name j = Yojson.Safe.Util.member name j

(* Everything that moves between runs, pinned to a fixed value of the same type,
   so the snapshot reviews shape and wording while reading as a real report. Rates
   are timing-dependent and pinned too; the mount snapshot exercises rate
   rendering with literals. *)
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
      (* A fresh root per run: a write through a route really reaches its store
         now, so a leftover object would answer the read this asserts is a
         miss. *)
      store = Local_backend.make ~root:(Filename.temp_dir "tsync-route-test" "");
      serve_share = None;
      socket_path = "/nonexistent/tsync.sock";
      domain_name = "one";
      self_frontend = `Assoc [];
      diagnose =
        (fun ~totals:_ ~exact:_ ~reload:_ ~frontends:_ ->
          Lwt.return (`Assoc []));
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
     silently unconfigurable. [shares] is on the frontend only: the client asks
     over /share-url rather than mirroring the setting. *)
  let has_field name specs =
    List.exists (fun (s : Field_spec.t) -> s.name = name) specs
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
    List.exists (fun (s : Field_spec.t) -> s.name = name) frontend_spec
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

  (* The store directory has to exist for its filesystem to be measurable — a
     capacity of "unknown" is what an absent path correctly reports. *)
  Lwt_main.run (Fs_util.mkdir_p (status_root ^ "/store"));

  (* A chunk in every shard: the estimate scales one shard's worth by the shard
     count, so a uniformly filled store is where estimate and truth must agree
     exactly. Real keys are hashes and approximate this distribution. *)
  let planted = Chunk_layout.shards in
  Lwt_main.run
    (Lwt_list.iter_s
       (fun i ->
         let key =
           Printf.sprintf "%s%013x-%016x" (Chunk_layout.shard_name i) i i
         in
         let (module B : Backend.S) = C.store in
         B.put
           ~key:(C.chunk_prefix ^ Chunk_layout.relative_path key)
           ~data:"chunk" ())
       (List.init planted Fun.id));

  (* A journal with a cursor set, so "to apply" is counted against something.
     Entries sit in month directories, so the count only comes out right if the
     cursor is compared against bare entry keys: with the directory kept, every
     entry sorts above the cursor and an idle client reports a permanent backlog.
     Only the one foreign entry past the cursor is behind — our own entries never
     are, whatever their timestamp. *)
  let module Fs = File_store.Make (C) in
  let module J = Journal.Make (C) in
  let other = "ffffffffffffffffffffffffffffffff" in
  let entry_key s =
    match Journal.Entry_key.of_string s with
      | Some ek -> ek
      | None -> failwith ("http_proxy_test: bad entry key " ^ s)
  in
  let cursor_entry = entry_key ("1785969965857-" ^ other) in
  let mine = J.client_uuid () in
  Lwt_main.run
    (Lwt_list.iter_s
       (fun entry ->
         let (module B : Backend.S) = C.store in
         B.put
           ~key:(C.journal_prefix ^ Journal.Entry_key.relative_path entry)
           ~data:"{}" ())
       [
         entry_key ("1785969965000-" ^ other);
         cursor_entry;
         entry_key ("1785969966000-" ^ other);
         entry_key ("1785969967000-" ^ mine);
       ]);
  Fs.write_last_sync_key cursor_entry;

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
  let report ?(totals = false) ?(exact = false) ?(reload = false) () =
    Lwt_main.run
      (Http_proxy_frontend.status_json ~port:8443 ~tls:true ~totals ~exact
         ~reload status_routes)
  in
  let r = report () in
  List.iter
    (fun key -> assert (json_member key r <> `Null))
    ["server"; "process"; "lwt"; "traffic"; "recentErrors"; "domains"];
  (* A shared listener's cpu and counters belong to every domain it serves, so
     they are reported here rather than filed under one. *)
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
  (* The listener appears as one of the domain's frontends carrying this domain's
     settings; the shared process figures are reported once, at the top. *)
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
     answering, named by the socket it was asked on. *)
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
  (* Asserted, not just snapshotted: a wrong backlog looks like a stalled sync. *)
  let journal = json_member "journal" (by_name "disk") in
  assert (json_member "entries" journal = `Int 4);
  assert (json_member "behind" journal = `Int 1);
  let archive = by_name "archive" in
  assert (json_member "reachable" archive = `Bool false);
  assert (json_member "error" archive <> `Null);
  let deferred = json_member "deferred" archive in
  assert (json_member "queued" deferred = `Int 7);
  assert (json_member "degraded" deferred = `Bool true);

  (* Counting is opt-in and never done while a request waits: the first ask
     starts a background walk and says so, a later one has the numbers, and the
     figure is then reported by every request until someone asks for a new one.
     Each state below is a row in the "store totals" snapshot. *)
  let totals_for name report =
    match json_member "domains" report with
      | `List [d] -> (
          match json_member "backends" d with
            | `List l ->
                json_member "totals"
                  (List.find (fun b -> json_member "name" b = `String name) l)
            | _ -> `Null)
      | _ -> `Null
  in
  let disk_totals = totals_for "disk" in
  (* One row: every field that carries meaning, and [sampledSecondsAgo] reduced
     to the fact that it is there — its value moves between runs. *)
  let totals_row label t =
    if t = `Null then Printf.sprintf "  %-30s (none reported)" label
    else (
      let field k =
        match json_member k t with
          | `Null -> None
          | `Int n -> Some (Printf.sprintf "%s=%d" k n)
          | `Bool b -> Some (Printf.sprintf "%s=%b" k b)
          | `String s -> Some (Printf.sprintf "%s=%s" k s)
          | _ -> None
      in
      let fields =
        List.filter_map field
          [
            "counting";
            "manifests";
            "chunks";
            "chunkBytes";
            "chunksFromShards";
            "refreshing";
            "error";
          ]
        @ if json_member "sampledSecondsAgo" t = `Null then [] else ["aged"]
      in
      Printf.sprintf "  %-30s %s" label (String.concat " " fields))
  in
  let rows = ref [] in
  let row label t = rows := !rows @ [totals_row label t] in

  row "not counted, not asked" (disk_totals (report ()));
  row "asked, nothing counted yet" (disk_totals (report ~totals:true ()));
  (* Let the background walk land. Bounded retry rather than a fixed sleep. *)
  let rec await ~ready ~what tries r =
    let t = disk_totals (r ()) in
    if ready t then t
    else if tries = 0 then failwith (what ^ " never arrived")
    else begin
      Lwt_main.run (Lwt_unix.sleep 0.05);
      await ~ready ~what (tries - 1) r
    end
  in
  let counted =
    await ~what:"counts"
      ~ready:(fun t -> json_member "chunks" t <> `Null)
      40
      (fun () -> report ~totals:true ())
  in
  row "estimate landed" counted;

  (* [exact] is a separate sample, answered with the estimate in hand until its
     walk lands — hence waiting on the absence of [chunksFromShards] rather than
     the presence of [chunks]. *)
  let exact =
    await ~what:"exact counts"
      ~ready:(fun t ->
        json_member "chunksFromShards" t = `Null
        && json_member "chunks" t <> `Null)
      40
      (fun () -> report ~totals:true ~exact:true ())
  in
  row "exact landed" exact;
  row "plain /stats, nothing asked" (disk_totals (report ()));
  row "recount asked" (disk_totals (report ~totals:true ~reload:true ()));
  row "store that cannot be read"
    (totals_for "archive" (report ~totals:true ()));

  (* An assertion, not just a snapshot: a snapshot can be promoted without being
     read, and a leaked shared secret must not ride in on a promote. *)
  assert (
    json_member "secret" (json_member "options" proxy_frontend) = `String "***");
  (* The same rule for a backend that points at a remote server. *)
  assert (
    json_member "secret" (json_member "config" (by_name "archive"))
    = `String "***");

  (* A domain's frontends are separate processes with separate counters, so the
     bytes a mount moves are invisible to the proxy's metrics. They come over IPC
     and are reported as that frontend's own, or a page showing its own zero calls
     a busy machine idle.

     Keys are exactly the ones [Ipc_handler] emits: a fixture that says [type]
     where the daemon says something else only proves the fixture agrees with the
     renderer. *)
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
  (* The cheap way and the thorough way. The store is one chunk per shard, so
     estimate and count agree on the number and differ only in how they say they
     got it. *)
  let totals_text ~exact =
    Diagnostics.text
      (substitute ~values:stable_values (report ~totals:true ~exact ()))
  in
  print_endline "########## /stats?totals=1 ##########";
  print_string (totals_text ~exact:false);
  print_endline "########## /stats?totals=exact ##########";
  print_string (totals_text ~exact:true);
  (* Every state a store's totals pass through, in the order they happen. *)
  print_endline "########## store totals, state by state ##########";
  List.iter print_endline !rows;
  print_endline "http_proxy_test ok"
