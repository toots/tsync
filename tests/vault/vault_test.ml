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

let secret_key () =
  p "== secret key\n";
  let raw = bytes Char.chr 16 in
  let spelled = Secret_key.to_string raw in
  p "id of 00..0f: %s\n" (Secret_key.id raw);
  p "00..0f: %s\n" spelled;
  let reads input =
    p "  %-40S -> %s\n" input
      (match Secret_key.of_string input with
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
  let fresh = Secret_key.generate () in
  check "a generated secret key reads back"
    (Secret_key.of_string (Secret_key.to_string fresh) = Some fresh)

let passphrase () =
  p "== passphrase\n";
  List.iter
    (fun (what, typed) ->
      p "  %-34s %s\n" what
        (match Passphrase.of_typed typed with
          | Ok bytes ->
              Printf.sprintf "accepted, %d bytes" (String.length bytes)
          | Error e -> "refused: " ^ e))
    [
      ("15 characters", String.make 15 'a');
      ("16 characters", String.make 16 'a');
      ("16 with surrounding spaces", "  " ^ String.make 16 'a' ^ " \n");
      ("15 with surrounding spaces", "  " ^ String.make 15 'a' ^ "  ");
      ("16 non-ASCII characters", String.concat "" (List.init 16 (fun _ -> "é")));
    ];
  let nfc = "\xc3\x9cn\xc3\xafcode passphrase"
  and nfd = "U\xcc\x88ni\xcc\x88code passphrase" in
  check "an NFC and an NFD spelling are two passphrases"
    (Passphrase.of_typed nfc <> Passphrase.of_typed nfd);
  check "surrounding white space does not change it"
    (Passphrase.of_typed ("  " ^ nfc ^ "\t") = Passphrase.of_typed nfc)

let keyring () =
  p "== keyring\n";
  let passphrase = "correct horse battery staple" in
  let secret_key = Secret_key.generate () in
  let key, ring = Keyring.create ~now:1760500000 ~secret_key passphrase in
  let text = Keyring.to_string ring in
  let unlock ?(secret_key = secret_key) ring passphrase =
    Keyring.unlock ring ~secret_key passphrase
  in
  check "unlocks with both secrets" (unlock ring passphrase = Ok key);
  check "the right secret key, a wrong passphrase: wrong passphrase"
    (unlock ring "correct horse battery stapler" = Error `Wrong_passphrase);
  check "the right passphrase, a wrong secret key: wrong secret key"
    (unlock ~secret_key:(Secret_key.generate ()) ring passphrase
    = Error `Wrong_secret_key);
  check "the secret key enrolls, another does not"
    (Keyring.enrolls ring ~secret_key_id:(Secret_key.id secret_key)
    && not
         (Keyring.enrolls ring
            ~secret_key_id:(Secret_key.id (Secret_key.generate ()))));
  check "the secret key is not in the keyring text"
    (not (contains text (hex secret_key)));
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
          (unlock r passphrase = Ok key);
        let out = Keyring.to_string r in
        check "unknown member dropped" (not (contains out "future"));
        check "unknown slot kept as read"
          (contains out {|{"id":"0000000000000000","kind":"device","pk":"x"}|});
        check "slots sorted by id, unknown first"
          (contains out
             ({|{"keyId":"|} ^ ring.key_id
            ^ {|","slots":[{"id":"0000000000000000"|})));
  (* Readers' limits *)
  let with_kdf key value =
    Yojson.Safe.to_string
      Yojson.Safe.Util.(
        let slot = List.hd slots in
        let kdf =
          match member "kdf" slot with
            | `Assoc l ->
                `Assoc
                  (List.map
                     (fun (k, v) -> if k = key then (k, value) else (k, v))
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
  List.iter
    (fun (what, key, value) ->
      match Keyring.of_string (with_kdf key value) with
        | Error e -> p "%s refused: %s\n" what e
        | Ok r ->
            check
              (what ^ ": skipped, not derived, and reported")
              (unlock r passphrase <> Ok key && Keyring.unusable r <> []))
    [
      ("memKiB above the limit", "memKiB", `Int (512 * 1024));
      ("memKiB 1", "memKiB", `Int 1);
      ("memKiB negative", "memKiB", `Int (-1));
      ("parallelism 0", "parallelism", `Int 0);
      ("iterations 0", "iterations", `Int 0);
      ("iterations negative", "iterations", `Int (-5));
    ];
  let small =
    { Keyring.recommended with mem_kib = 19 * 1024; iterations = 2 }
  in
  let nine =
    {
      ring with
      slots =
        List.init 9 (fun _ ->
            Keyring.slot ~params:small ~now:0 ~key_id:ring.key_id ~key
              ~secret_key passphrase);
    }
  in
  check "of nine slots, one is skipped"
    (List.length (Keyring.unusable nine) = 1 && unlock nine passphrase = Ok key);
  (* §4.2: the cap counts the slots of the secret key given, so nine other
     machines' slots, sorting first, leave this one's derived. *)
  let crowd =
    {
      ring with
      slots =
        List.hd ring.slots
        :: List.init 9 (fun i ->
            match
              Keyring.slot ~params:small ~now:0 ~key_id:ring.key_id ~key
                ~secret_key:(Secret_key.generate ()) passphrase
            with
              | Keyring.Secret_key s ->
                  Keyring.Secret_key { s with id = Printf.sprintf "%016d" i }
              | u -> u);
    }
  in
  check "nine other machines' slots do not crowd this one out"
    (unlock crowd passphrase = Ok key);
  check "a machine whose only slot is out of limits is told it is unusable"
    (match Keyring.of_string (with_kdf "memKiB" (`Int (512 * 1024))) with
      | Ok r -> (
          match unlock r passphrase with
            | Error (`Unusable [_]) -> true
            | _ -> false)
      | Error _ -> false);
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
  let other = "another passphrase of length" in
  let slot_a =
    Keyring.slot ~now:1 ~key_id:ring.key_id ~key ~secret_key passphrase
  in
  let slot_b = Keyring.slot ~now:2 ~key_id:ring.key_id ~key ~secret_key other in
  let a = { ring with slots = ring.slots @ [slot_a] } in
  let b = { ring with slots = ring.slots @ [slot_b] } in
  (match (Keyring.union a b, Keyring.union b a) with
    | Some ab, Some ba ->
        check "union holds every slot" (List.length ab.slots = 3);
        check "union is symmetric, bytewise"
          (Keyring.to_string ab = Keyring.to_string ba);
        check "both passphrases unlock the union"
          (unlock ab passphrase = Ok key && unlock ab other = Ok key)
    | _ -> p "union refused\n");
  let _, raced = Keyring.create ~now:3 ~secret_key other in
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
  secret_key ();
  passphrase ();
  keyring ();
  envelope ()
