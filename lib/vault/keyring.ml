type kdf = { mem_kib : int; iterations : int; parallelism : int; salt : string }

type slot =
  | Secret_key of {
      id : string;
      secret_key_id : string;
      kdf : kdf;
      nonce : string;
      wrapped : string;
      created : int;
      extra : (string * Yojson.Safe.t) list;
    }
  | Unknown of { id : string; json : Yojson.Safe.t }

type retired = { key_id : string; nonce : string; wrapped : string }

type t = {
  key_id : string;
  slots : slot list;
  retired : retired list;
  extra : (string * Yojson.Safe.t) list;
}

let recommended =
  { mem_kib = 65536; iterations = 3; parallelism = 1; salt = "" }

let min_mem_kib = 19 * 1024
let max_mem_kib = 256 * 1024
let max_iterations = 10
let max_parallelism = 4
let salt_size = 16
let wrapped_size = Crypto.key_size + Crypto.tag_size
let slot_id = function Secret_key { id; _ } | Unknown { id; _ } -> id

let is_hex16 s =
  String.length s = 16 && String.for_all Tsync_core.Names.is_hexlower s

let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let unb64 s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
    | Ok s -> s
    | Error _ -> failwith "base64url"

let slot_ad ~key_id id = "tsync-vault-slot/" ^ key_id ^ "/" ^ id

let retired_ad ~key_id retired_id =
  "tsync-vault-retired/" ^ key_id ^ "/" ^ retired_id

let retired_to_json (r : retired) =
  `Assoc
    [
      ("keyId", `String r.key_id);
      ("nonce", `String (b64 r.nonce));
      ("wrapped", `String (b64 r.wrapped));
    ]

let sort_retired retired =
  List.sort
    (fun (a : retired) (b : retired) -> String.compare a.key_id b.key_id)
    retired

let kdf_to_json kdf =
  `Assoc
    [
      ("alg", `String "argon2id");
      ("memKiB", `Int kdf.mem_kib);
      ("iterations", `Int kdf.iterations);
      ("parallelism", `Int kdf.parallelism);
      ("salt", `String (b64 kdf.salt));
    ]

let slot_to_json = function
  | Unknown { json; _ } -> json
  | Secret_key { id; secret_key_id; kdf; nonce; wrapped; created; extra } ->
      `Assoc
        ([
           ("id", `String id);
           ("kind", `String "secret-key");
           ("secretKeyId", `String secret_key_id);
           ("kdf", kdf_to_json kdf);
           ("nonce", `String (b64 nonce));
           ("wrapped", `String (b64 wrapped));
           ("created", `Int created);
         ]
        @ extra)

let canonical_slot slot = Yojson.Safe.to_string (slot_to_json slot)

let sort_slots slots =
  List.sort (fun a b -> String.compare (slot_id a) (slot_id b)) slots

let to_string t =
  Yojson.Safe.to_string
    (`Assoc
       (("keyId", `String t.key_id)
       :: ("slots", `List (List.map slot_to_json (sort_slots t.slots)))
       ::
         (match t.retired with
         | [] -> t.extra
         | retired ->
             ("retired", `List (List.map retired_to_json (sort_retired retired)))
             :: t.extra)))

let sized name size s =
  if String.length s <> size then failwith name;
  s

(* §4.1: the members a release does not know, kept through a rewrite in name
   order so equal content still gives equal bytes. *)
let unknown_members ~known json =
  List.sort
    (fun (a, _) (b, _) -> String.compare a b)
    (List.filter
       (fun (name, _) -> not (List.mem name known))
       (Yojson.Safe.Util.to_assoc json))

let kdf_of_json kdf =
  let open Yojson.Safe.Util in
  if to_string (member "alg" kdf) <> "argon2id" then failwith "kdf alg";
  {
    mem_kib = to_int (member "memKiB" kdf);
    iterations = to_int (member "iterations" kdf);
    parallelism = to_int (member "parallelism" kdf);
    salt = sized "salt" salt_size (unb64 (to_string (member "salt" kdf)));
  }

let slot_of_json json =
  let open Yojson.Safe.Util in
  let id = to_string (member "id" json) in
  if not (is_hex16 id) then failwith "slot id";
  match to_string (member "kind" json) with
    | "secret-key" ->
        let kdf = kdf_of_json (member "kdf" json) in
        let secret_key_id = to_string (member "secretKeyId" json) in
        if not (is_hex16 secret_key_id) then failwith "secretKeyId";
        Secret_key
          {
            id;
            secret_key_id;
            kdf;
            nonce =
              sized "nonce" Crypto.nonce_size
                (unb64 (to_string (member "nonce" json)));
            wrapped =
              sized "wrapped" wrapped_size
                (unb64 (to_string (member "wrapped" json)));
            created = to_int (member "created" json);
            extra =
              unknown_members json
                ~known:
                  [
                    "id";
                    "kind";
                    "secretKeyId";
                    "kdf";
                    "nonce";
                    "wrapped";
                    "created";
                  ];
          }
    | _ -> Unknown { id; json }

let retired_of_json json =
  let open Yojson.Safe.Util in
  let key_id = to_string (member "keyId" json) in
  if not (is_hex16 key_id) then failwith "retired keyId";
  {
    key_id;
    nonce =
      sized "retired nonce" Crypto.nonce_size
        (unb64 (to_string (member "nonce" json)));
    wrapped =
      sized "retired wrapped" wrapped_size
        (unb64 (to_string (member "wrapped" json)));
  }

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
    let retired =
      match member "retired" json with
        | `Null -> []
        | l -> List.map retired_of_json (to_list l)
    in
    let retired_ids = List.map (fun (r : retired) -> r.key_id) retired in
    if
      List.length (List.sort_uniq String.compare retired_ids)
      <> List.length retired_ids
    then failwith "duplicate retired keyId";
    {
      key_id;
      slots;
      retired;
      extra = unknown_members json ~known:["keyId"; "slots"; "retired"];
    }
  with
    | t -> Ok t
    | exception (Failure msg | Yojson.Json_error msg) -> Error msg
    | exception Yojson.Safe.Util.Type_error (msg, _) -> Error msg

let max_slots = 8

(* §4.2: the slot comes from the store; Argon2id is undefined below RFC 9106's
   floor. *)
let within_limits kdf =
  kdf.parallelism >= 1
  && kdf.parallelism <= max_parallelism
  && kdf.iterations >= 1
  && kdf.iterations <= max_iterations
  && kdf.mem_kib >= 8 * kdf.parallelism
  && kdf.mem_kib <= max_mem_kib

(* §4.2: the slots one unlock derives for, in slot id order. *)
let of_secret_key t ~secret_key_id =
  List.filter
    (function
      | Secret_key s -> s.secret_key_id = secret_key_id | Unknown _ -> false)
    (sort_slots t.slots)

(* §4.2: the cap counts the slots of one secret key, so other machines'
   enrolments never push this one's out. *)
let derivable t ~secret_key_id =
  List.filteri
    (fun i _ -> i < max_slots)
    (List.filter
       (function Secret_key { kdf; _ } -> within_limits kdf | _ -> false)
       (of_secret_key t ~secret_key_id))

(* §4.2: the secret key is Argon2id's secret value. *)
let kek kdf ~secret_key passphrase =
  Crypto.argon2id ~secret:secret_key ~mem_kib:kdf.mem_kib
    ~iterations:kdf.iterations ~parallelism:kdf.parallelism ~salt:kdf.salt
    passphrase

let slot ?(params = recommended) ~now ~key_id ~key ~secret_key passphrase =
  if
    params.mem_kib < min_mem_kib
    || params.iterations < 2 || params.parallelism <> 1
  then invalid_arg "Keyring.slot: KDF parameters below the minimum";
  let id = Tsync_core.Ids.hex (Tsync_core.Ids.urandom 8) in
  let kdf = { params with salt = Tsync_core.Ids.urandom salt_size } in
  let nonce = Tsync_core.Ids.urandom Crypto.nonce_size in
  let wrapped =
    Crypto.seal
      ~key:(kek kdf ~secret_key passphrase)
      ~nonce ~ad:(slot_ad ~key_id id) key
  in
  Secret_key
    {
      id;
      secret_key_id = Secret_key.id secret_key;
      kdf;
      nonce;
      wrapped;
      created = now;
      extra = [];
    }

let create ?params ~now ~secret_key passphrase =
  let key = Tsync_core.Ids.urandom Crypto.key_size in
  let key_id = Tsync_core.Ids.hex (Tsync_core.Ids.urandom 8) in
  ( key,
    {
      key_id;
      slots = [slot ?params ~now ~key_id ~key ~secret_key passphrase];
      retired = [];
      extra = [];
    } )

let unusable t =
  List.filter_map
    (function
      | Secret_key { id; secret_key_id; _ }
        when not
               (List.exists
                  (fun s -> slot_id s = id)
                  (derivable t ~secret_key_id)) ->
          Some id
      | _ -> None)
    (sort_slots t.slots)

let enrolls t ~secret_key_id =
  List.exists
    (function
      | Secret_key s -> s.secret_key_id = secret_key_id | Unknown _ -> false)
    t.slots

(* §4.2: a slot for another secret key is not derived for. *)
let unlock t ~secret_key passphrase =
  let secret_key_id = Secret_key.id secret_key in
  let own = of_secret_key t ~secret_key_id in
  let mine = derivable t ~secret_key_id in
  if own = [] then Error `Wrong_secret_key
  else if mine = [] then Error (`Unusable (List.map slot_id own))
  else (
    match
      List.find_map
        (function
          | Secret_key { id; kdf; nonce; wrapped; _ } ->
              Crypto.open_
                ~key:(kek kdf ~secret_key passphrase)
                ~nonce
                ~ad:(slot_ad ~key_id:t.key_id id)
                wrapped
          | Unknown _ -> None)
        mine
    with
      | Some key -> Ok key
      | None -> Error `Wrong_passphrase)

(* Spec §4.3: a union by slot id; for one id, the bytewise greatest canonical
   slot, so every client folding the same copies writes the same bytes. Copies
   whose unknown members differ are left to a release that knows how to fold
   them. *)
let union a b =
  if a.key_id <> b.key_id || a.extra <> b.extra then None
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
    let retired =
      List.fold_left
        (fun acc (r : retired) ->
          match
            List.partition (fun (o : retired) -> o.key_id = r.key_id) acc
          with
            | [], rest -> r :: rest
            | o :: _, rest ->
                let canonical x = Yojson.Safe.to_string (retired_to_json x) in
                (if String.compare (canonical o) (canonical r) >= 0 then o
                 else r)
                :: rest)
        [] (a.retired @ b.retired)
    in
    Some
      {
        a with
        slots = sort_slots (List.of_seq (Hashtbl.to_seq_values by_id));
        retired = sort_retired retired;
      })

(* §4.1: one already retired is kept as it is. *)
let retire t ~key (retired_id, retired_key) =
  if
    retired_id = t.key_id
    || List.exists (fun (r : retired) -> r.key_id = retired_id) t.retired
  then t
  else (
    let nonce = Tsync_core.Ids.urandom Crypto.nonce_size in
    let wrapped =
      Crypto.seal ~key ~nonce
        ~ad:(retired_ad ~key_id:t.key_id retired_id)
        retired_key
    in
    {
      t with
      retired =
        sort_retired ({ key_id = retired_id; nonce; wrapped } :: t.retired);
    })

let retire_all t ~key keys =
  List.fold_left (fun t retired -> retire t ~key retired) t keys

let retired_keys t ~key =
  List.partition_map
    (fun (r : retired) ->
      match
        Crypto.open_ ~key ~nonce:r.nonce
          ~ad:(retired_ad ~key_id:t.key_id r.key_id)
          r.wrapped
      with
        | Some k -> Left (r.key_id, k)
        | None -> Right r.key_id)
    t.retired

(* §7.2: the new keyring keeps what this version does not know of the old one;
   another machine's slots go, being what a re-key shuts out. *)
let succeed t ~key ~from ~from_key =
  let kept, lost = retired_keys from ~key:from_key in
  ( {
      (retire_all t ~key ((from.key_id, from_key) :: kept)) with
      extra = from.extra;
    },
    lost )
