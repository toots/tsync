let status_root = "/tmp/tsync-http-proxy-status-test"

module Down = Doubles.Down (struct
  let why = "connection refused"
end)

module C : Conf.S = struct
  let versioning = false
  let client_name = "test-client"
  let domain_name = "statusdom"
  let domain_prefix = "tsync/statusdom/manifests/"
  let chunk_prefix = "tsync/statusdom/chunks/"
  let versions_prefix = "tsync/statusdom/versions/"
  let journal_prefix = "tsync/statusdom/journal/"
  let cursor_key = Stored_key.in_space ~prefix:"tsync/statusdom/" "cursor"
  let shares_prefix = "tsync/shares/"

  let store =
    (* [verifyWrites] off: the chunks planted here are named to land one per
       shard, which a real content key cannot be made to do, so the store would
       rightly file every one of them as corrupt. *)
    Backend.make ~backend_type:"local"
      ~get_field:(function
        | "verifyWrites" -> Some "false" | _ -> Some (status_root ^ "/store"))
      ()

  (* Two stores, one of them down, so the report has to name which. *)
  let members =
    [
      Backend.member ~name:"disk"
        ~config:[("path", status_root ^ "/store")]
          (* A real path, so the capacity line is exercised — its numbers are
             whatever this machine has, hence pinned in the snapshot. *)
        ~local_path:(status_root ^ "/store") store;
      Backend.member ~name:"archive" ~role:`Backfill ~readable:false
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

let json_member name j = Yojson.Safe.Util.member name j

(* Everything that moves between runs, pinned to a fixed value of the same type,
   so the snapshot reviews shape and wording while reading as a real report. Rates
   are timing-dependent and pinned too; the mount snapshot exercises rate
   rendering with literals. *)
let stable_values =
  [
    ("hostname", `String "testhost");
    ("host", `String "testhost");
    ("pid", `Int 1234);
    ("startedAt", `Float 1700000000.);
    ("uptimeSeconds", `Float 3600.);
    ("cpuSeconds", `Float 12.5);
    ("cpuPercentAvg", `Float 0.3);
    ("rssBytes", `Int 41943040);
    ("privateBytes", `Int 39845888);
    ("swappedBytes", `Int 0);
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
    (* recentErrors entries, and the warnings they fold into: the message text
       is stable, the times are not. *)
    ("t", `Float 1700000000.);
    ("firstAt", `Float 1700000000.);
    ("lastAt", `Float 1700000000.);
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
    Http_proxy.Auth.request_headers ~secret ~meth:"GET" ~path
      ~body:Bigstring.empty ()
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
  and body = Bigstring.of_string "hello" in
  (* A freshly-signed request verifies. *)
  let headers = Http_proxy.Auth.request_headers ~secret ~meth ~path ~body () in
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
         ~body:(Bigstring.of_string "tampered")));
  assert (
    not
      (Http_proxy.Auth.verify ~secret ~meth ~path ~timestamp:ts
         ~signature:"deadbeef" ~body));

  (* A stale timestamp (outside the skew window) fails. *)
  let old_ts = Printf.sprintf "%.0f" (Unix.time () -. 1000.) in
  (* Signed the way a client signs, only under an old clock: what is being
     rejected is the timestamp, not the signature. *)
  let old_sig =
    List.assoc Http_proxy.Auth.signature_header
      (Http_proxy.Auth.request_headers ~timestamp:old_ts ~secret ~meth ~path
         ~body ())
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
      {
        Backend.key = Stored_key.listed "a";
        size = 3;
        last_modified = 1.5;
        etag = Some "v1";
      };
      {
        Backend.key = Stored_key.listed "b/c";
        size = 0;
        last_modified = 0.;
        etag = None;
      };
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
      store =
        Backend.make ~backend_type:"local"
          ~get_field:(fun _ -> Some (Scratch.dir "route-test"))
          ();
      serve_share = None;
      peers = [];
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
      Bigstring.empty
  in
  assert (
    chunk_size_op "tsync/one/" = Http_proxy_frontend.Chunk_size "tsync/one/");
  assert (
    Http_proxy_frontend.route_key (chunk_size_op "tsync/one/")
    = Some "tsync/one/");
  (* No prefix is a bad request, not a silent answer for some other domain. *)
  assert (
    Http_proxy_frontend.parse_op `GET
      (Uri.of_string "/chunk-size")
      Bigstring.empty
    = Http_proxy_frontend.Bad);

  assert (pick "tsync/two/manifests/x" "one" = Some "two");
  (* No route here serves /s/, so nothing on this listener reads the manifest
     back and the signer's own store is where it belongs. *)
  assert (pick "tsync/shares/deadbeef" "two" = Some "two");
  assert (pick "tsync/shares/deadbeef" "nobody" = None);
  assert (pick "elsewhere/x" "one" = None);

  (* A bulk op is routed and authorised by its first key and then run whole, so
     every key past the first is held against the route that first one chose.
     Without that, a client holding one domain's secret reads another's objects
     through a list whose head is its own — two domains on one listener share a
     bucket and differ only in prefix. *)
  let bulk path keys =
    Http_proxy_frontend.parse_op `POST (Uri.of_string path)
      (Bigstring.of_string
         (Yojson.Safe.to_string (`List (List.map (fun k -> `String k) keys))))
  in
  let scoped op =
    List.for_all
      (Http_proxy_frontend.within (route "one"))
      (Http_proxy_frontend.op_keys op)
  in
  let mine = "tsync/one/manifests/a" and theirs = "tsync/two/manifests/b" in
  assert (scoped (bulk "/get-multi" [mine; "tsync/one/manifests/b"]));
  (* Routed to "one" by its head, which is what makes the tail worth checking. *)
  assert (
    Http_proxy_frontend.route_key (bulk "/get-multi" [mine; theirs]) = Some mine);
  assert (not (scoped (bulk "/get-multi" [mine; theirs])));
  (* The same shape on the write side, which predates the batch. *)
  assert (not (scoped (bulk "/delete-multi" [mine; theirs])));

  (* Once a route does serve /s/, the manifest has to land in the store that will
     be read for it: written to one store and served from another, the link
     404s. So the share-enabled route answers whoever is asking... *)
  let sharing =
    [
      { (route "one") with Http_proxy_frontend.serve_share = None };
      {
        (route "two") with
        Http_proxy_frontend.serve_share =
          Some (fun ~token:_ ~sub:_ ~query:_ ~range:_ -> assert false);
      };
    ]
  in
  let pick_sharing key signer =
    Option.map
      (fun r -> r.Http_proxy_frontend.secret)
      (Http_proxy_frontend.route_for sharing ~key ~authed:(fun r ->
           r.Http_proxy_frontend.secret = signer))
  in
  assert (pick_sharing "tsync/shares/deadbeef" "two" = Some "two");
  (* ...and a caller holding only the other domain's secret is refused, rather
     than publishing a link into a store /s/ will never look in. *)
  assert (pick_sharing "tsync/shares/deadbeef" "one" = None);

  (* Specs are what [tsync config --edit] prompts from, so a field missing here is
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
    let resp, _ =
      Lwt_main.run
        (Http_proxy_frontend.exec r op ~body:(Bigstring.of_string "x"))
    in
    Cohttp.Code.code_of_status (Cohttp.Response.status resp)
  in
  let key = Stored_key.listed "tsync/one/manifests/x" in
  List.iter
    (fun op -> assert (status op ~read_only:true = 403))
    [
      Http_proxy_frontend.Put key;
      Http_proxy_frontend.Delete key;
      Http_proxy_frontend.Delete_multi [key];
      Http_proxy_frontend.Copy
        (key, Stored_key.listed (Stored_key.to_string key ^ "2"));
    ];
  (* Reads are unaffected: absent key, not forbidden. *)
  assert (status (Http_proxy_frontend.Get key) ~read_only:true = 404);
  (* And the same writes are permitted when the route is writable. *)
  assert (status (Http_proxy_frontend.Put key) ~read_only:false = 200);

  (* Sharing keeps working on a read-only domain: a share manifest lives outside
     the domain root and publishing one changes no content. Revoking likewise. *)
  let share_key = Stored_key.listed "tsync/shares/deadbeef" in
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
           ~key:
             (Stored_key.in_space ~prefix:C.chunk_prefix
                (Chunk_layout.relative_path key))
           ~data:(Bigstring.of_string "chunk")
           ())
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
           ~key:
             (Stored_key.in_space ~prefix:C.journal_prefix
                (Journal.Entry_key.relative_path entry))
           ~data:(Bigstring.of_string "{}") ())
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
  (* No peers: this listener is the only frontend the domain has here, which is
     what keeps the report from announcing a mount daemon that never ran. *)
  let status_routes =
    [Http_proxy_frontend.make_route [binding] ~peers:[] binding]
  in
  let report ?(totals = false) ?(exact = false) ?(reload = false) () =
    Lwt_main.run
      (Http_proxy_frontend.status_json ~port:8443 ~tls:true ~totals ~exact
         ~reload status_routes)
  in
  let r = report () in
  (* Taken here, beside [r], so nothing counted in between can explain a
     difference: what [tsync status] reads over IPC has to be the collection the
     HTTP endpoints render, or the two surfaces drift. *)
  let stop_asked = ref 0 in
  let ipc_full line =
    Lwt_main.run
      (Http_proxy_frontend.ipc_handler ~port:8443 ~tls:true
         ~request_stop:(fun () -> incr stop_asked)
         status_routes line)
  in
  let ipc line = Yojson.Safe.from_string (fst (ipc_full line)) in
  let ipc_stats = ipc {|{"action":"stats"}|} in
  (* What the report says is in the snapshot below; these bindings are for the
     assertions after it, which are about what must not be in it. *)
  let domain =
    match json_member "domains" r with
      | `List [d] -> d
      | _ -> failwith "expected exactly one domain"
  in
  let proxy_frontend =
    match json_member "frontends" domain with
      | `List l ->
          List.find (fun f -> json_member "type" f = `String "http-proxy") l
      | _ -> failwith "expected the listener among the domain's frontends"
  in
  let by_name name =
    match json_member "backends" domain with
      | `List l -> List.find (fun b -> json_member "name" b = `String name) l
      | _ -> failwith "expected the domain's backends"
  in

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
           status_routes req Bigstring.empty)
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

  (* /api/v1/stats and /stats are one collection rendered twice, so a diff here
     is the review of both. The JSON keeps raw counts; only the text spells
     sizes for a person. *)
  let stable = substitute ~values:stable_values r in
  print_endline "########## ipc stats ##########";
  Printf.printf "ok: %s\n" (Yojson.Safe.to_string (json_member "ok" ipc_stats));
  Printf.printf "same collection as /api/v1/stats: %b\n"
    (match ipc_stats with
      | `Assoc f ->
          substitute ~values:stable_values (`Assoc (List.remove_assoc "ok" f))
          = stable
      | _ -> false);
  List.iter
    (fun line -> print_endline (Yojson.Safe.to_string (ipc line)))
    ["not json"; {|{"action":"nope"}|}; "{}"];
  (* Answered, then the connection closes: a caller must hear that the listener
     was asked before it winds down. *)
  let stop_reply, stop_ctl = ipc_full {|{"action":"stop"}|} in
  Printf.printf "stop: %s closes=%b asked=%d\n" stop_reply (stop_ctl = `Stop)
    !stop_asked;
  print_endline "########## /api/v1/stats ##########";
  print_endline (Yojson.Safe.pretty_to_string stable);
  print_endline "########## /stats ##########";
  print_string (Status_report.text stable);
  (* The same report on a host that also mounts the domain. *)
  print_endline "########## /stats with a mount daemon ##########";
  print_string
    (Status_report.text
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
    Status_report.text
      (substitute ~values:stable_values (report ~totals:true ~exact ()))
  in
  print_endline "########## /stats?totals=1 ##########";
  print_string (totals_text ~exact:false);
  print_endline "########## /stats?totals=exact ##########";
  print_string (totals_text ~exact:true);
  (* Every state a store's totals pass through, in the order they happen. *)
  print_endline "########## store totals, state by state ##########";
  List.iter print_endline !rows;
  (* What a setup form asks before it has a config: the domains this secret is
     good for, and nothing at all without one. Last, so the counters it bumps do
     not land in the snapshots above. *)
  let domains req =
    let resp, body =
      Lwt_main.run
        (Http_proxy_frontend.serve_domains status_routes req Bigstring.empty)
    in
    (status_code resp, Lwt_main.run (Cohttp_lwt.Body.to_string body))
  in
  print_endline "########## /domains ##########";
  List.iter
    (fun (label, req) ->
      let code, listing = domains req in
      Printf.printf "  %-16s %d %s\n" label code listing)
    [
      ("unsigned", Cohttp.Request.make (Uri.of_string "/domains"));
      ("wrong secret", signed_request ~secret:"wrong" ~path:"/domains");
      ("signed", signed_request ~secret:"s3cr3t" ~path:"/domains");
    ];

  print_endline "http_proxy_test ok"
