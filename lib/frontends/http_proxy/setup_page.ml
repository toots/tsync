open Tsync_http
module L = Tsync_setup_link.Setup_link

let headers =
  [
    ("x-content-type-options", "nosniff");
    ("referrer-policy", "no-referrer");
    ("cache-control", "no-store");
  ]

let page (s : L.stored) =
  Share_server.fill Setup_assets.html
    [
      ( "__SETUP_DATA__",
        Share_server.script_json
          (Yojson.Safe.from_string (L.stored_to_string s)) );
      ("__QRCODE_JS__", Setup_assets.qrcode);
    ]

let answer ~json stored =
  let respond status content_type body =
    {
      Server.status;
      headers = ("content-type", content_type) :: headers;
      body = String body;
    }
  in
  match stored with
    | None -> respond 404 "text/plain; charset=utf-8" "not found\n"
    | Some (s : L.stored) when s.expires < Unix.gettimeofday () ->
        if json then
          respond 410 "application/json"
            (Printf.sprintf {|{"expires":%d}|} (int_of_float s.expires))
        else respond 410 "text/plain; charset=utf-8" "link expired\n"
    | Some s when json -> respond 200 "application/json" (L.stored_to_string s)
    | Some s ->
        {
          (respond 200 "text/html; charset=utf-8" (page s)) with
          headers =
            ("content-type", "text/html; charset=utf-8")
            :: ( "content-security-policy",
                 "default-src 'none'; script-src 'unsafe-inline'; style-src \
                  'unsafe-inline'; img-src data:; frame-ancestors 'none'" )
            :: headers;
        }
