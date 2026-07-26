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
      primary = Local_backend.make ~root:"/tmp/tsync-route-test";
      all_backends = [];
      serve_share = None;
    }
  in
  let routes = [route "one"; route "two"] in
  let pick key signer =
    Option.map
      (fun r -> r.Http_proxy_frontend.secret)
      (Http_proxy_frontend.route_for routes ~key ~authed:(fun r ->
           r.Http_proxy_frontend.secret = signer))
  in
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

  print_endline "http_proxy_test ok"
