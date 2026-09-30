open Tsync_core
open Tsync_store
module W = Tsync_http_proxy_client.Proxy_wire

let p fmt = Printf.printf (fmt ^^ "\n")
let empty = Bigstring.empty
let bs = Bigstring.of_string

let () =
  p "== signature vectors (§3.4)";
  let sig_ meth target body =
    W.signature ~secret:"s3cret" ~meth ~target ~timestamp:"1727600000" body
  in
  let cursor = W.encode_key (Key.v "tsync/docs/cursor") in
  p "key %s" cursor;
  p "%s"
    (sig_ "GET"
       ("/o/" ^ cursor ^ "?"
       ^ W.canonical_query [("last_seen", "0000000000100-peer"); ("wait", "30")]
       )
       empty);
  p "%s"
    (sig_ "PUT"
       ("/o/"
       ^ W.encode_key (Key.v "tsync/docs/manifests/ab/f-0")
       ^ "?if_absent=1")
       (bs "hello"));
  p "%s"
    (sig_ "GET"
       ("/list?"
       ^ W.canonical_query
           [("mode", "all"); ("prefix", "tsync/docs/manifests/")])
       empty);
  p "%s" (sig_ "GET" "/domains" empty);
  p "== verification (§12)";
  let target = "/o/x?offset=0&length=4" in
  let good = sig_ "GET" target empty in
  let check label ?(secret = "s3cret") ?(target = target) ?(signature = good)
      body =
    p "%-24s %b" label
      (W.verify ~secret ~meth:"GET" ~target ~timestamp:"1727600000" ~signature
         body)
  in
  check "fresh signature" empty;
  check "wrong secret" ~secret:"other" empty;
  check "tampered target" ~target:"/o/x?offset=1&length=4" empty;
  check "tampered body" (bs "x");
  check "upper-case hex" ~signature:(String.uppercase_ascii good) empty;
  List.iter
    (fun (label, ts) -> p "%-24s %b" label (W.fresh ~now:1727600000. ts))
    [
      ("timestamp now", "1727600000");
      ("timestamp +300", "1727600300");
      ("timestamp +301", "1727600301");
      ("non-decimal timestamp", "1.7e9");
      ("16 digits", "0001727600000000");
    ];
  p "== canonical query (§3.2)";
  let q = W.canonical_query [("prefix", "a b,+&é"); ("k=", "v=")] in
  p "%s" q;
  p "parses back: %b"
    (W.parse_query q = Some [("prefix", "a b,+&é"); ("k=", "v=")]);
  List.iter
    (fun raw ->
      p "%-12S %s" raw
        (match W.parse_query raw with Some _ -> "ok" | None -> "400"))
    ["a=1&a=2"; "a"; "a=%zz"; "a=%4"; "a=+"; ""];
  p "== keys";
  p "round trip: %b"
    (W.decode_key (W.encode_key (Key.v "tsync/d/élan & co"))
    = Some (Key.v "tsync/d/élan & co"));
  p "undecodable: %b" (W.decode_key "!!" = None);
  p "== listing JSON";
  let entries =
    [
      {
        Store.key = Key.v "tsync/d/a";
        size = 3;
        last_modified = 1727600000.25;
        etag = Some "\"9b2c\"";
      };
      {
        Store.key = Key.v "tsync/d/b";
        size = 0;
        last_modified = 1.;
        etag = None;
      };
    ]
  in
  let j = W.listing_to_json entries in
  p "%s" j;
  p "round trip: %b" (W.listing_of_json j = entries);
  p "not an array: %s"
    (try
       ignore (W.listing_of_json "{}");
       "ok"
     with Fail.E f -> Fail.kind_name f.kind);
  p "== get-multi frames (§4.3)";
  let bodies =
    [
      Some (bs "one");
      None;
      Some (bs "");
      Some (Bigstring.of_string (String.make 200_000 'z'));
    ]
  in
  let enc = W.encode_bodies bodies in
  let show = function
    | Some b -> string_of_int (Bigstring.length b)
    | None -> "absent"
  in
  p "decoded: %s"
    (String.concat "," (List.map show (W.decode_bodies ~count:4 enc)));
  let kind f =
    try
      ignore (f ());
      "ok"
    with Fail.E f -> Fail.kind_name f.kind
  in
  p "fewer keys than frames: %s" (kind (fun () -> W.decode_bodies ~count:3 enc));
  p "more keys than frames: %s" (kind (fun () -> W.decode_bodies ~count:5 enc));
  p "truncated body: %s"
    (kind (fun () ->
         W.decode_bodies ~count:4
           (Bigstring.sub enc ~off:0 ~len:(Bigstring.length enc - 1))));
  p "length cut in half: %s"
    (kind (fun () -> W.decode_bodies ~count:1 (bs "\000\000")));
  p "== children-multi frames (§4.3)";
  let pre = Key.prefix "tsync/d/manifests/x/" in
  let folder =
    {
      Store.prefix = pre;
      listing =
        [
          {
            Store.key = Key.v "tsync/d/manifests/x/f";
            size = 2;
            last_modified = 5.;
            etag = None;
          };
        ];
      bodies =
        [
          (Key.v "tsync/d/manifests/x/f", Some (bs "hi"));
          (Key.v "tsync/d/manifests/x/g", None);
        ];
    }
  in
  let enc = W.encode_folders [folder] in
  p "round trip: %b" (W.decode_folders ~asked:[pre] enc = [folder]);
  p "empty answer: %d folders"
    (List.length (W.decode_folders ~asked:[pre] Bigstring.empty));
  p "folder not asked for: %s"
    (kind (fun () -> W.decode_folders ~asked:[Key.prefix "tsync/d/other/"] enc));
  let stray = { folder with bodies = [(Key.v "tsync/d/elsewhere", None)] } in
  p "child outside its folder: %s"
    (kind (fun () -> W.decode_folders ~asked:[pre] (W.encode_folders [stray])))
