open Tsync_http
module L = Tsync_setup_link.Setup_link

let headers =
  [
    ("x-content-type-options", "nosniff");
    ("referrer-policy", "no-referrer");
    ("cache-control", "no-store");
  ]

let title (s : L.stored) =
  match s.about with
    | [] -> "Set up tsync"
    | about ->
        "Set up tsync: "
        ^ String.concat ", "
            (List.map
               (fun (a : L.about) -> Tsync_core.Domain_name.to_string a.name)
               about)

let page ~origin ~token (s : L.stored) =
  let esc = Share_server.html_escape in
  Share_server.fill Setup_assets.html
    [
      ("__OG_TITLE__", esc (title s));
      ( "__OG_DESC__",
        esc
          "Open this link on the device to set up: it shows the steps for each \
           system and a QR code to scan." );
      ("__OG_IMAGE__", esc (origin ^ "/join/" ^ token ^ "/preview"));
      ( "__SETUP_DATA__",
        Share_server.script_json
          (Yojson.Safe.from_string (L.stored_to_string s)) );
      ("__QRCODE_JS__", Setup_assets.qrcode);
    ]

let answer ~origin ~token what stored =
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
        if what = `Json then
          respond 410 "application/json"
            (Printf.sprintf {|{"expires":%d}|} (int_of_float s.expires))
        else respond 410 "text/plain; charset=utf-8" "link expired\n"
    | Some s when what = `Json ->
        respond 200 "application/json" (L.stored_to_string s)
    | Some _ when what = `Preview ->
        respond 200 "image/png" (Lazy.force Share_server.card)
    | Some s ->
        {
          (respond 200 "text/html; charset=utf-8" (page ~origin ~token s)) with
          headers =
            ("content-type", "text/html; charset=utf-8")
            :: ( "content-security-policy",
                 "default-src 'none'; script-src 'unsafe-inline'; style-src \
                  'unsafe-inline'; img-src data:; frame-ancestors 'none'" )
            :: headers;
        }
