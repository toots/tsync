type kdf = { mem_kib : int; iterations : int; parallelism : int; salt : string }

type slot =
  | Passphrase of {
      id : string;
      kdf : kdf;
      nonce : string;
      wrapped : string;
      created : int;
    }
  | Unknown of { id : string; json : Yojson.Safe.t }

type t = { key_id : string; slots : slot list }

let recommended =
  { mem_kib = 65536; iterations = 3; parallelism = 1; salt = "" }

let min_mem_kib = 19 * 1024
let max_mem_kib = 256 * 1024
let max_iterations = 10
let max_parallelism = 4
let salt_size = 16
let wrapped_size = Crypto.key_size + Crypto.tag_size
let slot_id = function Passphrase { id; _ } | Unknown { id; _ } -> id

let is_hex16 s =
  String.length s = 16
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let unb64 s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
    | Ok s -> s
    | Error _ -> failwith "base64url"

let slot_ad ~key_id id = "tsync-vault-slot/" ^ key_id ^ "/" ^ id

let slot_to_json = function
  | Unknown { json; _ } -> json
  | Passphrase { id; kdf; nonce; wrapped; created } ->
      `Assoc
        [
          ("id", `String id);
          ("kind", `String "passphrase");
          ( "kdf",
            `Assoc
              [
                ("alg", `String "argon2id");
                ("memKiB", `Int kdf.mem_kib);
                ("iterations", `Int kdf.iterations);
                ("parallelism", `Int kdf.parallelism);
                ("salt", `String (b64 kdf.salt));
              ] );
          ("nonce", `String (b64 nonce));
          ("wrapped", `String (b64 wrapped));
          ("created", `Int created);
        ]

let canonical_slot slot = Yojson.Safe.to_string (slot_to_json slot)

let sort_slots slots =
  List.sort (fun a b -> String.compare (slot_id a) (slot_id b)) slots

let to_string t =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("keyId", `String t.key_id);
         ("slots", `List (List.map slot_to_json (sort_slots t.slots)));
       ])

let sized name size s =
  if String.length s <> size then failwith name;
  s

let slot_of_json json =
  let open Yojson.Safe.Util in
  let id = to_string (member "id" json) in
  if not (is_hex16 id) then failwith "slot id";
  match to_string (member "kind" json) with
    | "passphrase" ->
        let kdf = member "kdf" json in
        if to_string (member "alg" kdf) <> "argon2id" then failwith "kdf alg";
        Passphrase
          {
            id;
            kdf =
              {
                mem_kib = to_int (member "memKiB" kdf);
                iterations = to_int (member "iterations" kdf);
                parallelism = to_int (member "parallelism" kdf);
                salt =
                  sized "salt" salt_size (unb64 (to_string (member "salt" kdf)));
              };
            nonce =
              sized "nonce" Crypto.nonce_size
                (unb64 (to_string (member "nonce" json)));
            wrapped =
              sized "wrapped" wrapped_size
                (unb64 (to_string (member "wrapped" json)));
            created = to_int (member "created" json);
          }
    | _ -> Unknown { id; json }

let of_string s =
  match
    let open Yojson.Safe.Util in
    let json = Yojson.Safe.from_string s in
    let key_id = to_string (member "keyId" json) in
    if not (is_hex16 key_id) then failwith "keyId";
    let slots = List.map slot_of_json (to_list (member "slots" json)) in
    let ids = List.map slot_id slots in
    if slots = [] then failwith "no slot";
    if List.length (List.sort_uniq String.compare ids) <> List.length ids then
      failwith "duplicate slot id";
    { key_id; slots }
  with
    | t -> Ok t
    | exception (Failure msg | Yojson.Json_error msg) -> Error msg
    | exception Yojson.Safe.Util.Type_error (msg, _) -> Error msg

let within_limits kdf =
  kdf.mem_kib <= max_mem_kib
  && kdf.iterations <= max_iterations
  && kdf.parallelism <= max_parallelism

let kek kdf passphrase =
  Crypto.argon2id ~mem_kib:kdf.mem_kib ~iterations:kdf.iterations
    ~parallelism:kdf.parallelism ~salt:kdf.salt passphrase

let passphrase_slot ?(params = recommended) ~now ~key_id ~key passphrase =
  if
    params.mem_kib < min_mem_kib
    || params.iterations < 2 || params.parallelism <> 1
  then invalid_arg "Keyring.passphrase_slot: KDF parameters below the minimum";
  let id = Tsync_core.Ids.hex (Tsync_core.Ids.urandom 8) in
  let kdf = { params with salt = Tsync_core.Ids.urandom salt_size } in
  let nonce = Tsync_core.Ids.urandom Crypto.nonce_size in
  let wrapped =
    Crypto.seal ~key:(kek kdf passphrase) ~nonce ~ad:(slot_ad ~key_id id) key
  in
  Passphrase { id; kdf; nonce; wrapped; created = now }

let create ?params ~now passphrase =
  let key = Tsync_core.Ids.urandom Crypto.key_size in
  let key_id = Tsync_core.Ids.hex (Tsync_core.Ids.urandom 8) in
  ( key,
    { key_id; slots = [passphrase_slot ?params ~now ~key_id ~key passphrase] }
  )

let unusable t =
  List.filter_map
    (function
      | Passphrase { id; kdf; _ } when not (within_limits kdf) -> Some id
      | _ -> None)
    t.slots

let unlock t passphrase =
  List.find_map
    (function
      | Passphrase { id; kdf; nonce; wrapped; _ } when within_limits kdf ->
          Crypto.open_ ~key:(kek kdf passphrase) ~nonce
            ~ad:(slot_ad ~key_id:t.key_id id)
            wrapped
      | _ -> None)
    t.slots

(* Spec §4.3: a union by slot id; for one id, the bytewise greatest canonical
   slot, so every client folding the same copies writes the same bytes. *)
let union a b =
  if a.key_id <> b.key_id then None
  else (
    let greatest x y =
      if String.compare (canonical_slot x) (canonical_slot y) >= 0 then x else y
    in
    let by_id = Hashtbl.create 8 in
    List.iter
      (fun slot ->
        let id = slot_id slot in
        Hashtbl.replace by_id id
          (match Hashtbl.find_opt by_id id with
            | Some old -> greatest old slot
            | None -> slot))
      (a.slots @ b.slots);
    Some
      { a with slots = sort_slots (List.of_seq (Hashtbl.to_seq_values by_id)) })
