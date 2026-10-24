module Dsa = Mirage_crypto_ec.P256.Dsa

let aaguid = "\x9f\xa7\xc1\x9f\xb0\xfa\x44\x4f\x85\x4b\x34\xc0\xb4\x52\x0b\x66"
let supported = [-7]
let sha256 s = Digestif.SHA256.(to_raw_string (digest_string s))

type cbor =
  | Int of int
  | Bytes of string
  | Text of string
  | Map of (cbor * cbor) list

(* RFC 8949 §4.2.1: shortest heads, map keys sorted by their encoded bytes. *)
let rec cbor_encode buf value =
  let head major n =
    let major = major lsl 5 in
    let add_be width =
      for i = width - 1 downto 0 do
        Buffer.add_uint8 buf ((n lsr (8 * i)) land 0xff)
      done
    in
    if n < 24 then Buffer.add_uint8 buf (major lor n)
    else if n < 0x100 then (
      Buffer.add_uint8 buf (major lor 24);
      add_be 1)
    else if n < 0x10000 then (
      Buffer.add_uint8 buf (major lor 25);
      add_be 2)
    else if n < 0x100000000 then (
      Buffer.add_uint8 buf (major lor 26);
      add_be 4)
    else (
      Buffer.add_uint8 buf (major lor 27);
      add_be 8)
  in
  match value with
    | Int n when n >= 0 -> head 0 n
    | Int n -> head 1 (-1 - n)
    | Bytes s ->
        head 2 (String.length s);
        Buffer.add_string buf s
    | Text s ->
        head 3 (String.length s);
        Buffer.add_string buf s
    | Map entries ->
        let encoded =
          List.map (fun (k, v) -> (cbor_to_string k, cbor_to_string v)) entries
        in
        head 5 (List.length entries);
        List.iter
          (fun (k, v) ->
            Buffer.add_string buf k;
            Buffer.add_string buf v)
          (List.sort (fun (a, _) (b, _) -> String.compare a b) encoded)

and cbor_to_string value =
  let buf = Buffer.create 64 in
  cbor_encode buf value;
  Buffer.contents buf

let private_of_scalar scalar =
  match Dsa.priv_of_octets scalar with
    | Ok key -> key
    | Error _ -> invalid_arg "Webauthn: the private key is not a P-256 scalar"

let rec generate_key () =
  let scalar = Tsync_core.Ids.urandom 32 in
  match Dsa.priv_of_octets scalar with
    | Ok _ -> scalar
    | Error _ -> generate_key ()

(* 0x04 ‖ x ‖ y. *)
let uncompressed_point scalar =
  Dsa.pub_to_octets (Dsa.pub_of_priv (private_of_scalar scalar))

(* SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING point }. *)
let spki_prefix =
  "\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00"

let public_key_spki scalar = spki_prefix ^ uncompressed_point scalar

let cose_key scalar =
  let point = uncompressed_point scalar in
  cbor_to_string
    (Map
       [
         (Int 1, Int 2);
         (Int 3, Int (-7));
         (Int (-1), Int 1);
         (Int (-2), Bytes (String.sub point 1 32));
         (Int (-3), Bytes (String.sub point 33 32));
       ])

type flags = { user_verified : bool }

let flag_up = 0x01
let flag_uv = 0x04
let flag_be = 0x08
let flag_bs = 0x10
let flag_at = 0x40

let authenticator_data ?attested ~rp_id flags () =
  let buf = Buffer.create 160 in
  Buffer.add_string buf (sha256 rp_id);
  Buffer.add_uint8 buf
    (flag_up lor flag_be lor flag_bs
    lor (if flags.user_verified then flag_uv else 0)
    lor if attested = None then 0 else flag_at);
  Buffer.add_int32_be buf 0l;
  Option.iter
    (fun (credential_id, private_key) ->
      if String.length credential_id > 1023 then
        invalid_arg "Webauthn: a credential id is at most 1023 bytes";
      Buffer.add_string buf aaguid;
      Buffer.add_uint16_be buf (String.length credential_id);
      Buffer.add_string buf credential_id;
      Buffer.add_string buf (cose_key private_key))
    attested;
  Buffer.contents buf

let attestation_object ~authenticator_data =
  cbor_to_string
    (Map
       [
         (Text "fmt", Text "none");
         (Text "attStmt", Map []);
         (Text "authData", Bytes authenticator_data);
       ])

(* A DER INTEGER of an unsigned big-endian magnitude. *)
let der_integer magnitude =
  let n = String.length magnitude in
  let rec first_significant i =
    if i < n - 1 && magnitude.[i] = '\x00' then first_significant (i + 1) else i
  in
  let start = first_significant 0 in
  let body = String.sub magnitude start (n - start) in
  let body = if Char.code body.[0] >= 0x80 then "\x00" ^ body else body in
  Printf.sprintf "\x02%c%s" (Char.chr (String.length body)) body

(* WebAuthn §6.3.3, ES256: the nonce drawn from the CSPRNG, not RFC 6979's,
   which mirage-crypto-ec warns leaks the key to side channels; its blinding,
   on by default where it has any, draws from mirage-crypto-rng's generator,
   seeded once here. *)
let rng = lazy (Mirage_crypto_rng_unix.use_default ())

let sign ~private_key ~authenticator_data ~client_data_hash =
  let key = private_of_scalar private_key in
  let digest = sha256 (authenticator_data ^ client_data_hash) in
  Lazy.force rng;
  let r, s = Dsa.sign ~key ~k:(generate_key ()) digest in
  let body = der_integer r ^ der_integer s in
  Printf.sprintf "\x30%c%s" (Char.chr (String.length body)) body

let valid_label label =
  label <> ""
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
       label

let ( let* ) = Result.bind

let origin_host origin =
  let* scheme, rest =
    match String.index_opt origin ':' with
      | Some i
        when String.length origin > i + 2 && String.sub origin i 3 = "://" ->
          Ok
            ( String.sub origin 0 i,
              String.sub origin (i + 3) (String.length origin - i - 3) )
      | _ -> Error "the origin is not scheme://host"
  in
  let* host =
    let host, port =
      match String.index_opt rest ':' with
        | Some i ->
            ( String.sub rest 0 i,
              Some (String.sub rest (i + 1) (String.length rest - i - 1)) )
        | None -> (rest, None)
    in
    match port with
      | Some port
        when port = ""
             || not (String.for_all (fun c -> c >= '0' && c <= '9') port) ->
          Error "the origin's port is not a number"
      | _ -> Ok (String.lowercase_ascii host)
  in
  let labels = String.split_on_char '.' host in
  if not (List.for_all valid_label labels) then
    Error "the origin's host is not a domain name"
  else if List.for_all (String.for_all (fun c -> c >= '0' && c <= '9')) labels
  then Error "the origin's host is an IP address"
  else (
    match scheme with
      | "https" -> Ok host
      | "http" when host = "localhost" -> Ok host
      | "http" -> Error "the origin is http and not localhost"
      | _ -> Error "the origin is not https")

let rp_id_allowed ~origin ~rp_id =
  let* host = origin_host origin in
  if not (List.mem rp_id (Passwords.suffixes host)) then
    Error "the RP ID is neither the origin's host nor a suffix of it"
    (* The implicit [*] rule makes [localhost] a public suffix. *)
  else if rp_id = "localhost" then Ok ()
  else if Passwords.is_public_suffix rp_id then
    Error "the RP ID is a public suffix"
  else (
    match Passwords.registrable host with
      | Some d when List.mem d (Passwords.suffixes rp_id) -> Ok ()
      | _ -> Error "the RP ID is above the origin's registrable domain")

let related_host rp_id =
  let rp_id = String.lowercase_ascii rp_id in
  let labels = String.split_on_char '.' rp_id in
  List.for_all valid_label labels
  && (not
        (String.for_all
           (fun c -> c >= '0' && c <= '9')
           (List.hd (List.rev labels))))
  && (not (Passwords.is_public_suffix rp_id))
  && Passwords.registrable rp_id <> None

let max_labels = 5

let trim_slash s =
  if String.ends_with ~suffix:"/" s then String.sub s 0 (String.length s - 1)
  else s

let same_origin a b =
  String.lowercase_ascii (trim_slash a) = String.lowercase_ascii (trim_slash b)

(* WebAuthn L3 §5.11.1: an origin past the fifth distinct registrable label is
   skipped, so one RP cannot vouch for any number of sites. *)
let related_allows ~origin body =
  let origins =
    match Yojson.Safe.from_string body with
      | `Assoc l -> (
          match List.assoc_opt "origins" l with
            | Some (`List l) ->
                List.filter_map (function `String s -> Some s | _ -> None) l
            | _ -> [])
      | _ -> []
      | exception Yojson.Json_error _ -> []
  in
  let label item =
    match origin_host (trim_slash item) with
      | Error _ -> None
      | Ok host -> (
          match Passwords.registrable host with
            | Some d -> Some (List.hd (String.split_on_char '.' d))
            | None -> None)
  in
  let rec walk seen = function
    | [] -> false
    | item :: rest -> (
        match label item with
          | None -> walk seen rest
          | Some l when List.length seen >= max_labels && not (List.mem l seen)
            ->
              walk seen rest
          | Some l ->
              same_origin item origin
              || walk (if List.mem l seen then seen else l :: seen) rest)
  in
  Result.is_ok (origin_host origin) && walk [] origins
