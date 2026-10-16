open Tsync_vault

let p fmt = Printf.printf fmt
let hex = Tsync_core.Ids.hex
let bytes f n = String.init n f
let check what b = p "%-60s %s\n" what (if b then "yes" else "NO")

let contains s sub =
  let n = String.length sub in
  let rec at i =
    i + n <= String.length s && (String.sub s i n = sub || at (i + 1))
  in
  at 0

let flip i s =
  String.mapi (fun j c -> if i = j then Char.chr (Char.code c lxor 1) else c) s

let argon2 () =
  p "== argon2id\n";
  (* RFC 9106 §5.3 *)
  p "RFC 9106 5.3: %s\n"
    (hex
       (Crypto.argon2id ~secret:(String.make 8 '\x03')
          ~ad:(String.make 12 '\x04') ~mem_kib:32 ~iterations:3 ~parallelism:4
          ~salt:(String.make 16 '\x02') (String.make 32 '\x01')));
  (* libsodium crypto_pwhash, ARGON2ID13, opslimit 3, memlimit 64 MiB *)
  p "libsodium 64MiB t=3: %s\n"
    (hex
       (Crypto.argon2id ~mem_kib:65536 ~iterations:3 ~parallelism:1
          ~salt:(String.make 16 's') "password"))

let xchacha () =
  p "== xchacha20-poly1305\n";
  (* draft-irtf-cfrg-xchacha-03 A.3.1 *)
  let key = bytes (fun i -> Char.chr (0x80 + i)) 32 in
  let nonce = bytes (fun i -> Char.chr (0x40 + i)) 24 in
  let ad = "\x50\x51\x52\x53\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7" in
  let plaintext =
    "Ladies and Gentlemen of the class of '99: If I could offer you only one \
     tip for the future, sunscreen would be it."
  in
  let sealed = Crypto.seal ~key ~nonce ~ad plaintext in
  p "A.3.1: %s\n" (hex sealed);
  check "opens" (Crypto.open_ ~key ~nonce ~ad sealed = Some plaintext);
  check "a flipped tag bit does not open"
    (Crypto.open_ ~key ~nonce ~ad (flip (String.length sealed - 1) sealed)
    = None);
  check "other ad does not open" (Crypto.open_ ~key ~nonce ~ad:"x" sealed = None)

let passphrase () =
  p "== passphrase\n";
  let raw = bytes Char.chr 16 in
  let spelled = Passphrase.to_string raw in
  p "00..0f: %s\n" spelled;
  let reads input =
    p "  %-40S -> %s\n" input
      (match Passphrase.of_string input with
        | Some r when r = raw -> "same"
        | Some r -> hex r
        | None -> "refused")
  in
  let compact = String.concat "" (String.split_on_char '-' spelled) in
  reads spelled;
  reads (String.uppercase_ascii spelled);
  reads compact;
  reads (String.concat " " (String.split_on_char '-' spelled));
  (* "0" and "1" typed as "o" and "l"/"i" *)
  reads (String.map (function '0' -> 'o' | '1' -> 'l' | c -> c) spelled);
  reads (String.map (function '1' -> 'I' | c -> c) spelled);
  reads (String.sub compact 0 25);
  reads (compact ^ "0");
  (* last symbol "1" sets a padding bit *)
  reads (String.sub compact 0 25 ^ "1");
  reads (String.sub compact 0 25 ^ "u");
  let fresh = Passphrase.generate () in
  check "a generated passphrase reads back"
    (Passphrase.of_string (Passphrase.to_string fresh) = Some fresh)

let keyring () =
  p "== keyring\n";
  let passphrase = Passphrase.generate () in
  let key, ring = Keyring.create ~now:1760500000 passphrase in
  let text = Keyring.to_string ring in
  check "unlocks with its passphrase" (Keyring.unlock ring passphrase = Some key);
  check "a wrong passphrase fails"
    (Keyring.unlock ring (Passphrase.generate ()) = None);
  check "parse then write gives the same bytes"
    (Result.map Keyring.to_string (Keyring.of_string text) = Ok text);
  check "K is not in the keyring text"
    (not (contains text (Base64.encode_string key) || contains text (hex key)));
  (* Unknown members and kinds; slots out of order. *)
  let json = Yojson.Safe.from_string text in
  let slots = Yojson.Safe.Util.(to_list (member "slots" json)) in
  let unknown =
    `Assoc
      [
        ("id", `String "0000000000000000");
        ("kind", `String "device");
        ("pk", `String "x");
      ]
  in
  let mangled =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("future", `Int 1);
           ("slots", `List (slots @ [unknown]));
           ("keyId", `String ring.key_id);
         ])
  in
  (match Keyring.of_string mangled with
    | Error e -> p "mangled keyring refused: %s\n" e
    | Ok r ->
        check "unknown kind and members: still unlocks"
          (Keyring.unlock r passphrase = Some key);
        let out = Keyring.to_string r in
        check "unknown member dropped" (not (contains out "future"));
        check "unknown slot kept as read"
          (contains out {|{"id":"0000000000000000","kind":"device","pk":"x"}|});
        check "slots sorted by id, unknown first"
          (contains out
             ({|{"keyId":"|} ^ ring.key_id
            ^ {|","slots":[{"id":"0000000000000000"|})));
  (* Readers' limits *)
  let greedy =
    Yojson.Safe.to_string
      Yojson.Safe.Util.(
        let slot = List.hd slots in
        let kdf = member "kdf" slot in
        let kdf =
          match kdf with
            | `Assoc l ->
                `Assoc
                  (List.map
                     (function
                       | "memKiB", _ -> ("memKiB", `Int (512 * 1024)) | kv -> kv)
                     l)
            | j -> j
        in
        `Assoc
          [
            ("keyId", `String ring.key_id);
            ( "slots",
              `List
                [
                  (match slot with
                    | `Assoc l ->
                        `Assoc
                          (List.map
                             (function "kdf", _ -> ("kdf", kdf) | kv -> kv)
                             l)
                    | j -> j);
                ] );
          ])
  in
  (match Keyring.of_string greedy with
    | Error e -> p "greedy refused: %s\n" e
    | Ok r ->
        check "a slot above the memory limit is skipped"
          (Keyring.unlock r passphrase = None);
        check "and reported" (Keyring.unusable r <> []));
  (* Corrupt keyrings *)
  List.iter
    (fun (what, s) ->
      p "  %-30s %s\n" what
        (match Keyring.of_string s with
          | Ok _ -> "accepted"
          | Error _ -> "CORRUPT"))
    [
      ("not json", "{");
      ("no slot", Printf.sprintf {|{"keyId":%S,"slots":[]}|} ring.key_id);
      ("as written", text);
      ( "upper-case key id",
        (* the key id is bytes 10 to 25 of {"keyId":"<16 hex>", *)
        String.sub text 0 10
        ^ String.uppercase_ascii ring.key_id
        ^ String.sub text 26 (String.length text - 26) );
    ];
  (* The fold *)
  let other = Passphrase.generate () in
  let slot_a =
    Keyring.passphrase_slot ~now:1 ~key_id:ring.key_id ~key passphrase
  in
  let slot_b = Keyring.passphrase_slot ~now:2 ~key_id:ring.key_id ~key other in
  let a = { ring with slots = ring.slots @ [slot_a] } in
  let b = { ring with slots = ring.slots @ [slot_b] } in
  (match (Keyring.union a b, Keyring.union b a) with
    | Some ab, Some ba ->
        check "union holds every slot" (List.length ab.slots = 3);
        check "union is symmetric, bytewise"
          (Keyring.to_string ab = Keyring.to_string ba);
        check "both passphrases unlock the union"
          (Keyring.unlock ab passphrase = Some key
          && Keyring.unlock ab other = Some key)
    | _ -> p "union refused\n");
  let _, raced = Keyring.create ~now:3 other in
  check "different key ids do not fold" (Keyring.union ring raced = None)

let envelope () =
  p "== envelope\n";
  let key = Tsync_core.Ids.urandom 32 in
  let key_id = "0123456789abcdef" in
  let body = Envelope.seal ~key ~key_id ~extension:"totp" "secret" in
  let show what r =
    p "  %-40s %s\n" what
      (match r with
        | Ok s -> "opens: " ^ s
        | Error `Corrupt -> "CORRUPT"
        | Error (`Other_key id) -> "under key " ^ id)
  in
  p "length for 6 bytes: %d\n" (String.length body);
  check "two seals differ"
    (body <> Envelope.seal ~key ~key_id ~extension:"totp" "secret");
  let opens = Envelope.open_ ~key ~key_id in
  show "as written" (opens ~extension:"totp" body);
  show "in another extension" (opens ~extension:"passwords" body);
  show "a flipped ciphertext bit" (opens ~extension:"totp" (flip 40 body));
  show "a flipped key id bit" (opens ~extension:"totp" (flip 11 body));
  show "another magic"
    (opens ~extension:"totp"
       ("tsv2" ^ String.sub body 4 (String.length body - 4)));
  show "51 bytes" (opens ~extension:"totp" (String.sub body 0 51));
  (* A body whose header names the keyring's id but was sealed under another. *)
  let foreign =
    Envelope.seal ~key:(Tsync_core.Ids.urandom 32) ~key_id ~extension:"totp" "x"
  in
  show "sealed under another K, same id" (opens ~extension:"totp" foreign)

let () =
  argon2 ();
  xchacha ();
  passphrase ();
  keyring ();
  envelope ()
