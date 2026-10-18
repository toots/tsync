type algorithm = [ `SHA1 | `SHA256 | `SHA512 ]

type t = {
  issuer : string;
  account : string;
  secret : string;
  algorithm : algorithm;
  digits : int;
  period : int;
  modified : int;
  unknown : (string * Yojson.Safe.t) list;
}

let base32_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

(* RFC 4648 base32, upper case, no padding; [None] for any other symbol, and
   for trailing bits that are not zero unless [lenient]. *)
let base32_decode ?(lenient = false) s =
  let n = String.length s in
  let out = Buffer.create (n * 5 / 8) in
  let rec go i acc bits =
    if i = n then
      if lenient || acc land ((1 lsl bits) - 1) = 0 then Some () else None
    else (
      match String.index_opt base32_alphabet s.[i] with
        | None -> None
        | Some v ->
            let acc = (acc lsl 5) lor v and bits = bits + 5 in
            if bits >= 8 then (
              Buffer.add_char out (Char.chr ((acc lsr (bits - 8)) land 0xff));
              go (i + 1) (acc land ((1 lsl (bits - 8)) - 1)) (bits - 8))
            else go (i + 1) acc bits)
  in
  Option.map (fun () -> Buffer.contents out) (go 0 0 0)

let base32_encode bytes =
  let out = Buffer.create ((String.length bytes * 8 / 5) + 1) in
  let acc = ref 0 and bits = ref 0 in
  String.iter
    (fun c ->
      acc := (!acc lsl 8) lor Char.code c;
      bits := !bits + 8;
      while !bits >= 5 do
        Buffer.add_char out base32_alphabet.[(!acc lsr (!bits - 5)) land 31];
        bits := !bits - 5;
        acc := !acc land ((1 lsl !bits) - 1)
      done)
    bytes;
  if !bits > 0 then
    Buffer.add_char out base32_alphabet.[(!acc lsl (5 - !bits)) land 31];
  Buffer.contents out

(* §5.1: any case, with or without padding, stored as §2 says. *)
let normal_secret s =
  let s =
    String.uppercase_ascii
      (String.concat "" (String.split_on_char '=' (String.trim s)))
  in
  match base32_decode ~lenient:true s with
    | Some seed when String.length seed >= 1 && String.length seed <= 128 ->
        Ok (base32_encode seed)
    | Some _ -> Error "the secret decodes to 1 to 128 bytes"
    | None -> Error "the secret is not base32"

let algorithm_of_string = function
  | "SHA1" -> Some `SHA1
  | "SHA256" -> Some `SHA256
  | "SHA512" -> Some `SHA512
  | _ -> None

let algorithm_to_string = function
  | `SHA1 -> "SHA1"
  | `SHA256 -> "SHA256"
  | `SHA512 -> "SHA512"

(* §2: every rule a record must keep, for a parsed plaintext and a URI alike. *)
let check t =
  if t.issuer = "" && t.account = "" then Error "issuer and account are empty"
  else if t.digits < 6 || t.digits > 8 then Error "digits is 6 to 8"
  else if t.period < 1 || t.period > 300 then Error "period is 1 to 300 seconds"
  else (
    match normal_secret t.secret with
      | Ok s when s = t.secret -> Ok t
      | Ok _ -> Error "the secret is not in its stored form"
      | Error e -> Error e)

let known =
  ["issuer"; "account"; "secret"; "algorithm"; "digits"; "period"; "modified"]

let of_string s =
  match Yojson.Safe.from_string s with
    | exception Yojson.Json_error e -> Error e
    | `Assoc l -> (
        let str k =
          match List.assoc_opt k l with Some (`String v) -> Some v | _ -> None
        and int k =
          match List.assoc_opt k l with Some (`Int v) -> Some v | _ -> None
        in
        match
          ( str "issuer",
            str "account",
            str "secret",
            Option.bind (str "algorithm") algorithm_of_string,
            int "digits",
            int "period",
            int "modified" )
        with
          | ( Some issuer,
              Some account,
              Some secret,
              Some algorithm,
              Some digits,
              Some period,
              Some modified ) ->
              check
                {
                  issuer;
                  account;
                  secret;
                  algorithm;
                  digits;
                  period;
                  modified;
                  unknown = List.filter (fun (k, _) -> not (List.mem k known)) l;
                }
          | _ -> Error "a required member is missing or of the wrong type")
    | _ -> Error "not a JSON object"

let to_string t =
  Yojson.Safe.to_string
    (`Assoc
       ([
          ("issuer", `String t.issuer);
          ("account", `String t.account);
          ("secret", `String t.secret);
          ("algorithm", `String (algorithm_to_string t.algorithm));
          ("digits", `Int t.digits);
          ("period", `Int t.period);
          ("modified", `Int t.modified);
        ]
       @ t.unknown))

(* §3: the key fields of the grouped fold. *)
let code_fields t =
  String.concat "\000"
    [
      t.secret;
      algorithm_to_string t.algorithm;
      string_of_int t.digits;
      string_of_int t.period;
    ]

let hmac algorithm ~key msg =
  match algorithm with
    | `SHA1 -> Digestif.SHA1.(to_raw_string (hmac_string ~key msg))
    | `SHA256 -> Digestif.SHA256.(to_raw_string (hmac_string ~key msg))
    | `SHA512 -> Digestif.SHA512.(to_raw_string (hmac_string ~key msg))

(* §4: RFC 6238 with T0 = 0. *)
let code_at t ~unix_time =
  let counter = Int64.div unix_time (Int64.of_int t.period) in
  let msg = Bytes.create 8 in
  Bytes.set_int64_be msg 0 counter;
  let key = Option.get (base32_decode t.secret) in
  let mac = hmac t.algorithm ~key (Bytes.to_string msg) in
  let byte i = Char.code mac.[i] in
  let offset = byte (String.length mac - 1) land 0x0f in
  let value =
    ((byte offset land 0x7f) lsl 24)
    lor (byte (offset + 1) lsl 16)
    lor (byte (offset + 2) lsl 8)
    lor byte (offset + 3)
  in
  let modulus = int_of_float (10. ** float_of_int t.digits) in
  Printf.sprintf "%0*d" t.digits (value mod modulus)

let seconds_left t ~unix_time =
  t.period - Int64.to_int (Int64.rem unix_time (Int64.of_int t.period))

let percent_decode s =
  match Tsync_core.Text.percent_unescape s with
    | Some s -> Ok s
    | None -> Error "a bad percent escape"

let percent_encode =
  Tsync_core.Text.percent_escape ~allowed:(function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
    | _ -> false)

let ( let* ) = Result.bind

(* §5.1: the Google Authenticator key-URI format. *)
(* §5.1: the label splits on its first literal [:], each part decoded after;
   one with no literal [:] splits on a decoded one. *)
let split_label raw =
  let part s = Result.map String.trim (percent_decode s) in
  match String.index_opt raw ':' with
    | Some i ->
        let* issuer = part (String.sub raw 0 i) in
        let* account =
          part (String.sub raw (i + 1) (String.length raw - i - 1))
        in
        Ok (Some issuer, account)
    | None -> (
        let* label = percent_decode raw in
        match String.index_opt label ':' with
          | Some i ->
              Ok
                ( Some (String.trim (String.sub label 0 i)),
                  String.trim
                    (String.sub label (i + 1) (String.length label - i - 1)) )
          | None -> Ok (None, String.trim label))

let decimal v =
  if v <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) v
  then int_of_string_opt v
  else None

(* §5: no reason names a value, which may hold the seed. *)
let of_uri ~now uri =
  let prefix = "otpauth://" in
  let n = String.length prefix in
  if
    String.length uri < n
    || String.lowercase_ascii (String.sub uri 0 n) <> prefix
  then Error "not an otpauth URI"
  else (
    let rest = String.sub uri n (String.length uri - n) in
    let type_end =
      match (String.index_opt rest '/', String.index_opt rest '?') with
        | Some s, Some q -> min s q
        | Some i, None | None, Some i -> i
        | None, None -> String.length rest
    in
    let kind = String.sub rest 0 type_end in
    if String.lowercase_ascii kind <> "totp" then
      Error "only otpauth://totp/ URIs are kept"
    else (
      let rest =
        let from =
          if type_end < String.length rest && rest.[type_end] = '/' then
            type_end + 1
          else type_end
        in
        String.sub rest from (String.length rest - from)
      in
      let label, query =
        match String.index_opt rest '?' with
          | Some i ->
              ( String.sub rest 0 i,
                String.sub rest (i + 1) (String.length rest - i - 1) )
          | None -> (rest, "")
      in
      let* label_issuer, account = split_label label in
      let* params =
        List.fold_left
          (fun acc kv ->
            let* acc = acc in
            if kv = "" then Ok acc
            else (
              let k, v =
                match String.index_opt kv '=' with
                  | Some i ->
                      ( String.sub kv 0 i,
                        String.sub kv (i + 1) (String.length kv - i - 1) )
                  | None -> (kv, "")
              in
              let* v = percent_decode v in
              Ok ((String.lowercase_ascii k, v) :: acc)))
          (Ok [])
          (String.split_on_char '&' query)
      in
      let param k = List.assoc_opt k params in
      let issuer =
        match (param "issuer", label_issuer) with
          | Some i, _ -> i
          | None, Some i -> i
          | None, None -> ""
      in
      let int k default =
        match param k with
          | None -> Ok default
          | Some v -> (
              match decimal v with
                | Some n -> Ok n
                | None -> Error (k ^ " is not a number"))
      in
      let* secret =
        match param "secret" with
          | Some s when s <> "" -> normal_secret s
          | _ -> Error "the secret is missing"
      in
      let* algorithm =
        match param "algorithm" with
          | None -> Ok `SHA1
          | Some a -> (
              match algorithm_of_string (String.uppercase_ascii a) with
                | Some a -> Ok a
                | None -> Error "unknown algorithm")
      in
      let* digits = int "digits" 6 in
      let* period = int "period" 30 in
      check
        {
          issuer;
          account;
          secret;
          algorithm;
          digits;
          period;
          modified = now;
          unknown = [];
        }))

(* §5.3: a bare secret, which services print in groups. *)
let of_secret ~now ~issuer ~account secret =
  let* secret =
    match String.concat "" (String.split_on_char ' ' secret) with
      | "" -> Error "the secret is missing"
      | secret -> normal_secret secret
  in
  check
    {
      issuer = String.trim issuer;
      account = String.trim account;
      secret;
      algorithm = `SHA1;
      digits = 6;
      period = 30;
      modified = now;
      unknown = [];
    }

let to_uri t =
  let label =
    if t.issuer = "" then
      (if String.contains t.account ':' then ":" else "")
      ^ percent_encode t.account
    else percent_encode t.issuer ^ ":" ^ percent_encode t.account
  in
  Printf.sprintf
    "otpauth://totp/%s?secret=%s%s&algorithm=%s&digits=%d&period=%d" label
    t.secret
    (if t.issuer = "" then "" else "&issuer=" ^ percent_encode t.issuer)
    (algorithm_to_string t.algorithm)
    t.digits t.period
