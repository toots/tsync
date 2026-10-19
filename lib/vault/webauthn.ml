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

(* RFC 3492 with the IDNA parameters, for the list's U-labels. *)
let punycode code_points =
  let base = 36 and tmin = 1 and tmax = 26 in
  let digit d = Char.chr (if d < 26 then d + 97 else d + 22) in
  let adapt delta numpoints first =
    let delta = if first then delta / 700 else delta / 2 in
    let delta = ref (delta + (delta / numpoints)) and k = ref 0 in
    while !delta > (base - tmin) * tmax / 2 do
      delta := !delta / (base - tmin);
      k := !k + base
    done;
    !k + ((base - tmin + 1) * !delta / (!delta + 38))
  in
  let out = Buffer.create 32 in
  List.iter
    (fun c -> if c < 0x80 then Buffer.add_char out (Char.chr c))
    code_points;
  let basic = Buffer.length out in
  if basic > 0 then Buffer.add_char out '-';
  let total = List.length code_points in
  let n = ref 128 and delta = ref 0 and bias = ref 72 and handled = ref basic in
  while !handled < total do
    let m =
      List.fold_left
        (fun m c -> if c >= !n && c < m then c else m)
        max_int code_points
    in
    delta := !delta + ((m - !n) * (!handled + 1));
    n := m;
    List.iter
      (fun c ->
        if c < !n then incr delta
        else if c = !n then (
          let q = ref !delta and k = ref base and fin = ref false in
          while not !fin do
            let t =
              if !k <= !bias then tmin
              else if !k >= !bias + tmax then tmax
              else !k - !bias
            in
            if !q < t then fin := true
            else (
              Buffer.add_char out (digit (t + ((!q - t) mod (base - t))));
              q := (!q - t) / (base - t);
              k := !k + base)
          done;
          Buffer.add_char out (digit !q);
          bias := adapt !delta (!handled + 1) (!handled = basic);
          delta := 0;
          incr handled))
      code_points;
    incr delta;
    incr n
  done;
  Buffer.contents out

let code_points label =
  let rec go i acc =
    if i >= String.length label then List.rev acc
    else (
      let d = String.get_utf_8_uchar label i in
      go
        (i + Uchar.utf_decode_length d)
        (Uchar.to_int (Uchar.utf_decode_uchar d) :: acc))
  in
  go 0 []

let a_label label =
  if String.for_all (fun c -> Char.code c < 0x80) label then label
  else "xn--" ^ punycode (code_points label)

type rules = {
  normal : (string, unit) Hashtbl.t;
  wildcard : (string, unit) Hashtbl.t;  (** keyed by the part after [*.] *)
  exception_ : (string, unit) Hashtbl.t;  (** keyed by the part after [!] *)
}

let rules =
  lazy
    (let rules =
       {
         normal = Hashtbl.create 16384;
         wildcard = Hashtbl.create 64;
         exception_ = Hashtbl.create 16;
       }
     in
     List.iter
       (fun line ->
         match String.split_on_char ' ' (String.trim line) with
           | rule :: _
             when rule <> "" && not (String.starts_with ~prefix:"//" rule) ->
               let rule =
                 String.concat "."
                   (List.map a_label (String.split_on_char '.' rule))
               in
               let after prefix =
                 let p = String.length prefix in
                 String.sub rule p (String.length rule - p)
               in
               if String.starts_with ~prefix:"!" rule then
                 Hashtbl.replace rules.exception_ (after "!") ()
               else if String.starts_with ~prefix:"*." rule then
                 Hashtbl.replace rules.wildcard (after "*.") ()
               else Hashtbl.replace rules.normal rule ()
           | _ -> ())
       (String.split_on_char '\n' Psl_data.text);
     rules)

(* [d] and each suffix of it at a label boundary, longest first. *)
let rec suffixes d =
  match String.index_opt d '.' with
    | None -> [d]
    | Some i -> d :: suffixes (String.sub d (i + 1) (String.length d - i - 1))

(* The PSL algorithm: a matching exception rule prevails and makes the public
   suffix shorter than [d]; otherwise [d] is a public suffix when a rule names
   it exactly, a wildcard rule names its parent, or it is a single label (the
   implicit [*]). *)
let is_public_suffix d =
  let d = String.lowercase_ascii d in
  let rules = Lazy.force rules in
  let parent =
    match suffixes d with _ :: parent :: _ -> Some parent | _ -> None
  in
  (not (List.exists (Hashtbl.mem rules.exception_) (suffixes d)))
  && (Hashtbl.mem rules.normal d
     || Option.fold ~none:true ~some:(Hashtbl.mem rules.wildcard) parent)

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
  if not (List.mem rp_id (suffixes host)) then
    Error "the RP ID is neither the origin's host nor a suffix of it"
    (* The implicit [*] rule makes [localhost] a public suffix. *)
  else if rp_id = "localhost" then Ok ()
  else if is_public_suffix rp_id then Error "the RP ID is a public suffix"
  else Ok ()
