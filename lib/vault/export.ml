module X25519 = Mirage_crypto_ec.X25519

type record = { extension : string; name : string; plaintext : string }

type payload = {
  created : int;
  domain : string;
  keys : (string * string) list;
  appearance : string option;
  backup_key : string option;
  records : record list;
}

type header = [ `Secret_key of string | `Backup_key of string ]
type backup_key = { id : string; public : string }

let version = 1
let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let unb64 s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
    | Ok s -> s
    | Error _ -> failwith "base64url"

let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))
let hex16 s = Tsync_core.Ids.hex (String.sub (sha256 s) 0 8)

let is_hex16 s =
  String.length s = 16 && String.for_all Tsync_core.Names.is_hexlower s

let ad kind id = Printf.sprintf "tsync-vault-export/%d/%s/%s" version kind id

let payload_to_string p =
  let opt name = function Some v -> [(name, `String v)] | None -> [] in
  Yojson.Safe.to_string
    (`Assoc
       ([
          ("created", `Int p.created);
          ("domain", `String p.domain);
          ( "keys",
            `List
              (List.map
                 (fun (id, key) ->
                   `Assoc [("keyId", `String id); ("key", `String (b64 key))])
                 p.keys) );
        ]
       @ opt "appearance" p.appearance
       @ opt "backupKey" p.backup_key
       @ [
           ( "records",
             `List
               (List.map
                  (fun r ->
                    `Assoc
                      [
                        ("extension", `String r.extension);
                        ("name", `String r.name);
                        ("plaintext", `String (b64 r.plaintext));
                      ])
                  p.records) );
         ]))

(* §8.2: an import writes nothing before every part of it reads. *)
let payload_of_string s =
  let open Yojson.Safe.Util in
  match
    let json = Yojson.Safe.from_string s in
    let str k j = to_string (member k j) in
    let opt k = match member k json with `String v -> Some v | _ -> None in
    let keys =
      List.map
        (fun j ->
          let id = str "keyId" j and key = unb64 (str "key" j) in
          if not (is_hex16 id) then failwith "a key id";
          if String.length key <> Crypto.key_size then failwith "a key";
          (id, key))
        (to_list (member "keys" json))
    in
    if keys = [] then failwith "no key";
    let leaf what v =
      if v = "" || v = "." || v = ".." || String.contains v '/' then
        failwith what;
      v
    in
    {
      created = to_int (member "created" json);
      domain = str "domain" json;
      keys;
      appearance = opt "appearance";
      backup_key = opt "backupKey";
      records =
        List.map
          (fun j ->
            {
              extension = leaf "an extension" (str "extension" j);
              name = leaf "a record name" (str "name" j);
              plaintext = unb64 (str "plaintext" j);
            })
          (to_list (member "records" json));
    }
  with
    | p -> Ok p
    | exception (Failure m | Yojson.Json_error m) -> Error m
    | exception Type_error (m, _) -> Error m

let file ~seal ~nonce ~sealed =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("tsyncVaultExport", `Int version);
         ("seal", seal);
         ("nonce", `String (b64 nonce));
         ("sealed", `String (b64 sealed));
       ])

(* The parts every reader needs, with the seal's own members. *)
let parts text =
  let open Yojson.Safe.Util in
  match
    let json = Yojson.Safe.from_string text in
    if member "tsyncVaultExport" json <> `Int version then
      failwith "not a vault export of this version";
    let seal = member "seal" json in
    let nonce = unb64 (to_string (member "nonce" json)) in
    if String.length nonce <> Crypto.nonce_size then failwith "the nonce";
    (seal, nonce, unb64 (to_string (member "sealed" json)))
  with
    | parts -> Ok parts
    | exception (Failure m | Yojson.Json_error m) -> Error m
    | exception Type_error (m, _) -> Error m

let header text =
  Result.bind (parts text) (fun (seal, _, _) ->
      let open Yojson.Safe.Util in
      match
        ( to_string_option (member "kind" seal),
          to_string_option (member "secretKeyId" seal),
          to_string_option (member "backupKeyId" seal) )
      with
        | Some "secret-key", Some id, _ when is_hex16 id -> Ok (`Secret_key id)
        | Some "backup-key", _, Some id when is_hex16 id -> Ok (`Backup_key id)
        | _ -> Error "an unknown seal")

let opened ~key ~ad ~nonce sealed =
  match Crypto.open_ ~key ~nonce ~ad sealed with
    | None -> Error `Wrong
    | Some s -> Result.map_error (fun m -> `Corrupt m) (payload_of_string s)

(* §8.2: the readers' limits of a keyring slot (§9). *)
let kdf_of_json kdf =
  let open Yojson.Safe.Util in
  let int k = to_int (member k kdf) in
  let mem_kib = int "memKiB"
  and iterations = int "iterations"
  and parallelism = int "parallelism"
  and salt = unb64 (to_string (member "salt" kdf)) in
  if
    to_string (member "alg" kdf) <> "argon2id"
    || mem_kib < 8 * parallelism
    || mem_kib > 256 * 1024
    || iterations < 1 || iterations > 10 || parallelism < 1 || parallelism > 4
    || String.length salt <> 16
  then failwith "the KDF parameters";
  (mem_kib, iterations, parallelism, salt)

let seal_with_vault ~secret_key ~passphrase p =
  let r = Keyring.recommended in
  let salt = Tsync_core.Ids.urandom 16
  and nonce = Tsync_core.Ids.urandom Crypto.nonce_size
  and id = Secret_key.id secret_key in
  let key =
    Crypto.argon2id ~secret:secret_key ~mem_kib:r.mem_kib
      ~iterations:r.iterations ~parallelism:r.parallelism ~salt passphrase
  in
  file ~nonce
    ~seal:
      (`Assoc
         [
           ("kind", `String "secret-key");
           ("secretKeyId", `String id);
           ( "kdf",
             `Assoc
               [
                 ("alg", `String "argon2id");
                 ("memKiB", `Int r.mem_kib);
                 ("iterations", `Int r.iterations);
                 ("parallelism", `Int r.parallelism);
                 ("salt", `String (b64 salt));
               ] );
         ])
    ~sealed:
      (Crypto.seal ~key ~nonce ~ad:(ad "secret-key" id) (payload_to_string p))

let open_with_vault ~secret_key ~passphrase text =
  match parts text with
    | Error m -> Error (`Corrupt m)
    | Ok (seal, nonce, sealed) -> (
        match kdf_of_json (Yojson.Safe.Util.member "kdf" seal) with
          | exception (Failure m | Yojson.Safe.Util.Type_error (m, _)) ->
              Error (`Corrupt m)
          | mem_kib, iterations, parallelism, salt ->
              let key =
                Crypto.argon2id ~secret:secret_key ~mem_kib ~iterations
                  ~parallelism ~salt passphrase
              in
              opened ~key ~nonce sealed
                ~ad:(ad "secret-key" (Secret_key.id secret_key)))

let backup_key_of_seed seed =
  match X25519.secret_of_octets (sha256 ("tsync-vault-backup-key/" ^ seed)) with
    | Ok (_, public) ->
        { id = hex16 ("tsync-vault-backup-key-id/" ^ public); public }
    | Error _ -> invalid_arg "Export.backup_key_of_seed"

let backup_key_to_string k ~created =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("keyId", `String k.id);
         ("publicKey", `String (b64 k.public));
         ("created", `Int created);
       ])

let backup_key_of_string s =
  let open Yojson.Safe.Util in
  match
    let json = Yojson.Safe.from_string s in
    let public = unb64 (to_string (member "publicKey" json)) in
    let id = to_string (member "keyId" json) in
    if
      String.length public <> 32
      || id <> hex16 ("tsync-vault-backup-key-id/" ^ public)
    then failwith "not a backup key";
    { id; public }
  with
    | k -> Ok k
    | exception (Failure m | Yojson.Json_error m) -> Error m
    | exception Type_error (m, _) -> Error m

(* §8.3: an ephemeral X25519 exchange with the public half, so the sealing
   machine cannot open what it sealed. *)
let shared_key ~shared ~ephemeral ~public =
  sha256 ("tsync-vault-backup/" ^ shared ^ ephemeral ^ public)

let seal_to_backup k p =
  let secret, ephemeral =
    match X25519.secret_of_octets (Tsync_core.Ids.urandom 32) with
      | Ok pair -> pair
      | Error _ -> invalid_arg "Export.seal_to_backup"
  in
  let shared =
    match X25519.key_exchange secret k.public with
      | Ok s -> s
      | Error _ -> invalid_arg "Export.seal_to_backup: the public key"
  in
  let nonce = Tsync_core.Ids.urandom Crypto.nonce_size in
  file ~nonce
    ~seal:
      (`Assoc
         [
           ("kind", `String "backup-key");
           ("backupKeyId", `String k.id);
           ("ephemeral", `String (b64 ephemeral));
         ])
    ~sealed:
      (Crypto.seal
         ~key:(shared_key ~shared ~ephemeral ~public:k.public)
         ~nonce ~ad:(ad "backup-key" k.id) (payload_to_string p))

let open_with_backup ~seed text =
  match parts text with
    | Error m -> Error (`Corrupt m)
    | Ok (seal, nonce, sealed) -> (
        let k = backup_key_of_seed seed in
        match
          ( X25519.secret_of_octets (sha256 ("tsync-vault-backup-key/" ^ seed)),
            unb64 Yojson.Safe.Util.(to_string (member "ephemeral" seal)) )
        with
          | exception (Failure m | Yojson.Safe.Util.Type_error (m, _)) ->
              Error (`Corrupt m)
          | Error _, _ -> Error `Wrong
          | Ok (secret, _), ephemeral -> (
              match X25519.key_exchange secret ephemeral with
                | Error _ -> Error (`Corrupt "the ephemeral key")
                | Ok shared ->
                    opened ~nonce sealed
                      ~key:(shared_key ~shared ~ephemeral ~public:k.public)
                      ~ad:(ad "backup-key" k.id)))
