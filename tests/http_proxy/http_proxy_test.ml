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

  print_endline "http_proxy_test ok"
