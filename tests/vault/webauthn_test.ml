(* The passkey authenticator's bytes and RP ID check (spec extensions/passwords
   §7.2, §7.3). *)

open Tsync_vault
module Dsa = Mirage_crypto_ec.P256.Dsa

let p fmt = Printf.printf fmt

let hex s =
  String.concat ""
    (List.map (Printf.sprintf "%02x")
       (List.map Char.code (List.of_seq (String.to_seq s))))

let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))
let private_key = sha256 "tsync webauthn test key"
let credential_id = sha256 "tsync webauthn test credential"
let rp_id = "example.com"

(* The COSE_Key's x and y, at their fixed offsets in an ES256 key. *)
let public_of_cose cose =
  match
    Dsa.pub_of_octets ("\x04" ^ String.sub cose 10 32 ^ String.sub cose 45 32)
  with
    | Ok key -> key
    | Error _ -> failwith "COSE key does not decode"

(* SEQUENCE { INTEGER r, INTEGER s }, each left-padded to 32 bytes. *)
let r_s_of_der der =
  let integer at =
    assert (der.[at] = '\x02');
    let len = Char.code der.[at + 1] in
    let body = String.sub der (at + 2) len in
    assert (len = 1 || body.[0] <> '\x00' || Char.code body.[1] >= 0x80);
    assert (Char.code body.[0] < 0x80);
    let body = if len = 33 then String.sub body 1 32 else body in
    (String.make (32 - String.length body) '\x00' ^ body, at + 2 + len)
  in
  assert (der.[0] = '\x30');
  assert (Char.code der.[1] = String.length der - 2);
  let r, at = integer 2 in
  let s, at = integer at in
  assert (at = String.length der);
  (r, s)

let flag_names byte =
  String.concat " "
    (List.filter_map
       (fun (bit, name) -> if byte land bit <> 0 then Some name else None)
       [(0x01, "UP"); (0x04, "UV"); (0x08, "BE"); (0x10, "BS"); (0x40, "AT")])

let print_authenticator_data label data =
  p "%s: %d bytes\n" label (String.length data);
  p "  rpIdHash %s\n"
    (if String.sub data 0 32 = sha256 rp_id then "= SHA-256(rpId)" else "WRONG");
  p "  flags    0x%02x %s\n"
    (Char.code data.[32])
    (flag_names (Char.code data.[32]));
  p "  count    %s\n" (hex (String.sub data 33 4));
  if String.length data > 37 then (
    p "  aaguid   %s\n" (hex (String.sub data 37 16));
    let len = (Char.code data.[53] lsl 8) lor Char.code data.[54] in
    p "  credLen  %d\n" len;
    p "  credId   %s\n" (hex (String.sub data 55 len));
    p "  coseKey  %s\n"
      (hex (String.sub data (55 + len) (String.length data - 55 - len))))

let bytes () =
  p "== §7.2 constants\n";
  p "aaguid %s\n" (hex Webauthn.aaguid);
  p "supported [%s]\n"
    (String.concat "; " (List.map string_of_int Webauthn.supported));
  p "\n== authenticator data\n";
  let created uv =
    Webauthn.authenticator_data
      ~attested:(credential_id, private_key)
      ~rp_id { user_verified = uv } ()
  in
  print_authenticator_data "create" (created false);
  print_authenticator_data "create, UV" (created true);
  print_authenticator_data "assert"
    (Webauthn.authenticator_data ~rp_id { user_verified = false } ());
  print_authenticator_data "assert, UV"
    (Webauthn.authenticator_data ~rp_id { user_verified = true } ());
  p "\n== attestation object\n";
  p "%s\n"
    (hex (Webauthn.attestation_object ~authenticator_data:(created false)));
  p "\n== SPKI\n";
  let spki = Webauthn.public_key_spki private_key in
  p "%d bytes: %s\n" (String.length spki) (hex spki);
  (match X509.Public_key.decode_der spki with
    | Ok (`P256 key) ->
        let ours =
          Result.get_ok (Dsa.priv_of_octets private_key) |> Dsa.pub_of_priv
        in
        p "x509 decodes P256, %s\n"
          (if Dsa.pub_to_octets key = Dsa.pub_to_octets ours then "same key"
           else "OTHER KEY");
        p "x509 re-encodes %s\n"
          (if X509.Public_key.encode_der (`P256 key) = spki then "identically"
           else "DIFFERENTLY")
    | Ok _ -> p "x509 decodes another key type\n"
    | Error (`Msg m) -> p "x509 refuses: %s\n" m);
  p "\n== signature\n";
  let authenticator_data = created true in
  let cose =
    String.sub authenticator_data (55 + 32)
      (String.length authenticator_data - 87)
  in
  let key = public_of_cose cose in
  let client_data_hash = sha256 "{\"type\":\"webauthn.create\"}" in
  let digest = sha256 (authenticator_data ^ client_data_hash) in
  let verifies der = Dsa.verify ~key (r_s_of_der der) digest in
  let rounds = 64 in
  let ok = ref 0 in
  for _ = 1 to rounds do
    let der =
      Webauthn.sign ~private_key ~authenticator_data ~client_data_hash
    in
    if verifies der then incr ok
  done;
  p "signatures verifying against the COSE key: %d/%d\n" !ok rounds;
  let der = Webauthn.sign ~private_key ~authenticator_data ~client_data_hash in
  let flipped = Bytes.of_string der in
  let last = Bytes.length flipped - 1 in
  Bytes.set flipped last (Char.chr (Char.code (Bytes.get flipped last) lxor 1));
  p "flipped signature byte verifies: %b\n" (verifies (Bytes.to_string flipped));
  let other =
    Webauthn.sign ~private_key ~authenticator_data
      ~client_data_hash:(sha256 "other")
  in
  p "signature of other client data verifies: %b\n" (verifies other);
  let fresh = Webauthn.generate_key () in
  p "generated key: %d bytes, signs: %b\n" (String.length fresh)
    (let ad =
       Webauthn.authenticator_data ~attested:(credential_id, fresh) ~rp_id
         { user_verified = false } ()
     in
     let key = public_of_cose (String.sub ad 87 (String.length ad - 87)) in
     let der =
       Webauthn.sign ~private_key:fresh ~authenticator_data:ad ~client_data_hash
     in
     Dsa.verify ~key (r_s_of_der der) (sha256 (ad ^ client_data_hash)))

let rp_ids () =
  p "\n== §7.3 RP ID\n";
  List.iter
    (fun (origin, rp_id) ->
      p "%-32s %-16s %s\n" origin rp_id
        (match Webauthn.rp_id_allowed ~origin ~rp_id with
          | Ok () -> "ok"
          | Error e -> "refused: " ^ e))
    [
      ("https://login.example.com", "example.com");
      ("https://login.example.com", "login.example.com");
      ("https://login.example.com:8443", "example.com");
      ("https://Login.Example.com", "example.com");
      ("https://evil.github.io", "github.io");
      ("https://evil.github.io", "evil.github.io");
      ("https://evil.s3.amazonaws.com", "amazonaws.com");
      ("https://evil.s3.amazonaws.com", "s3.amazonaws.com");
      ("https://evil.s3.amazonaws.com", "evil.s3.amazonaws.com");
      ("https://login.example.amazonaws.com", "amazonaws.com");
      ("http://example.com", "example.com");
      ("https://example.com", "other.com");
      ("https://example.com", "ample.com");
      ("https://example.com", "com");
      ("http://localhost:8080", "localhost");
      ("https://localhost", "localhost");
      ("https://a.b.co.uk", "b.co.uk");
      ("https://co.uk", "co.uk");
      ("https://a.b.ck", "b.ck");
      ("https://a.b.ck", "a.b.ck");
      ("https://www.ck", "www.ck");
      ("https://192.168.1.1", "1.1");
      ("https://example.com/path", "example.com");
      ("https://example.com:", "example.com");
      ("ftp://example.com", "example.com");
      ("example.com", "example.com");
    ];
  p "\n== public suffixes\n";
  List.iter
    (fun d -> p "%-20s %b\n" d (Passwords.is_public_suffix d))
    [
      "com";
      "example.com";
      "co.uk";
      "github.io";
      "ck";
      "b.ck";
      "www.ck";
      "a.www.ck";
      "unknowntld";
      "xn--55qx5d.cn";
      "example.xn--55qx5d.cn";
      "kawasaki.jp";
      "c.kawasaki.jp";
      "city.kawasaki.jp";
    ]

let related () =
  p "\n== §7.3 related origins\n";
  List.iter
    (fun d -> p "%-24s %b\n" d (Webauthn.related_host d))
    ["accounts.meta.com"; "com"; "co.uk"; "evil.com/x"; "a b.com"];
  let meta =
    {|{"origins": ["https://www.facebook.com", "https://www.instagram.com/"]}|}
  in
  let six =
    {|{"origins": ["https://a.one.com", "https://b.two.com", "https://three.com",
     "https://four.co.uk", "https://five.org", "https://www.one.com",
     "https://six.com"]}|}
  in
  List.iter
    (fun (origin, body) ->
      p "%-28s %b\n" origin (Webauthn.related_allows ~origin body))
    [
      ("https://www.facebook.com", meta);
      ("https://WWW.Instagram.com", meta);
      ("https://evil.facebook.com", meta);
      ("http://www.facebook.com", {|{"origins": ["http://www.facebook.com"]}|});
      ("https://www.facebook.com", "not json");
      ("https://www.facebook.com", {|{"origins": "https://www.facebook.com"}|});
      (* A sixth label is past the limit; a fifth label's second origin is not. *)
      ("https://www.one.com", six);
      ("https://six.com", six);
    ]

let () =
  bytes ();
  rp_ids ();
  related ()
