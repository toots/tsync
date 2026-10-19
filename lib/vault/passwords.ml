type site = string

let ( let* ) = Result.bind
let check cond reason = if cond then Ok () else Error reason

type web = { scheme : string; host : string; port : int }
type parsed = Web of web | Android of string

let default_port = function "https" -> 443 | _ -> 80

(* RFC 3492. *)
module Punycode = struct
  let base = 36
  let tmin = 1
  let tmax = 26

  let adapt ~first ~points delta =
    let delta = if first then delta / 700 else delta / 2 in
    let delta = delta + (delta / points) in
    let rec go delta k =
      if delta > (base - tmin) * tmax / 2 then
        go (delta / (base - tmin)) (k + base)
      else k + ((base - tmin + 1) * delta / (delta + 38))
    in
    go delta 0

  let digit d = Char.chr (if d < 26 then d + 97 else d - 26 + 48)

  let encode code_points =
    let out = Buffer.create 64 in
    List.iter
      (fun c -> if c < 128 then Buffer.add_char out (Char.chr c))
      code_points;
    let basic = Buffer.length out in
    if basic > 0 then Buffer.add_char out '-';
    let total = List.length code_points in
    let rec round ~n ~delta ~bias ~handled =
      if handled < total then (
        let m =
          List.fold_left
            (fun m c -> if c >= n && c < m then c else m)
            max_int code_points
        in
        let delta = ref (delta + ((m - n) * (handled + 1)))
        and bias = ref bias
        and handled = ref handled in
        List.iter
          (fun c ->
            if c < m then incr delta
            else if c = m then (
              let rec emit q k =
                let t =
                  if k <= !bias then tmin
                  else if k >= !bias + tmax then tmax
                  else k - !bias
                in
                if q < t then Buffer.add_char out (digit q)
                else (
                  Buffer.add_char out (digit (t + ((q - t) mod (base - t))));
                  emit ((q - t) / (base - t)) (k + base))
              in
              emit !delta base;
              bias :=
                adapt ~first:(!handled = basic) ~points:(!handled + 1) !delta;
              delta := 0;
              incr handled))
          code_points;
        round ~n:(m + 1) ~delta:(!delta + 1) ~bias:!bias ~handled:!handled)
    in
    round ~n:128 ~delta:0 ~bias:72 ~handled:basic;
    Buffer.contents out
end

let code_points s =
  let rec go i acc =
    if i >= String.length s then List.rev acc
    else (
      let d = String.get_utf_8_uchar s i in
      go
        (i + Uchar.utf_decode_length d)
        (Uchar.to_int (Uchar.utf_decode_uchar d) :: acc))
  in
  go 0 []

let is_ldh = function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false

(* ponytail: non-ASCII is not case-mapped (UTS #46); [Bücher] and [bücher]
   give two A-labels. *)
let a_label label =
  let label =
    if String.for_all (fun c -> Char.code c < 128) label then
      String.lowercase_ascii label
    else
      "xn--"
      ^ Punycode.encode
          (List.map
             (fun c ->
               if c < 128 then Char.code (Char.lowercase_ascii (Char.chr c))
               else c)
             (code_points label))
  in
  if String.length label < 1 || String.length label > 63 then
    Error "a host label is not 1 to 63 bytes"
  else if not (String.for_all is_ldh label) then
    Error "the host has a character a host cannot hold"
  else Ok label

let parse_host host =
  if host = "" then Error "the site has no host"
  else if host.[0] = '[' then
    if
      String.length host > 2
      && host.[String.length host - 1] = ']'
      && String.for_all
           (function '0' .. '9' | 'a' .. 'f' | ':' | '.' -> true | _ -> false)
           (String.lowercase_ascii (String.sub host 1 (String.length host - 2)))
    then Ok (String.lowercase_ascii host)
    else Error "the host is not an IPv6 address"
  else if not (String.is_valid_utf_8 host) then Error "the host is not UTF-8"
  else
    let* labels =
      List.fold_right
        (fun label acc ->
          let* acc = acc in
          let* label = a_label label in
          Ok (label :: acc))
        (String.split_on_char '.' host)
        (Ok [])
    in
    let host = String.concat "." labels in
    let* () = check (String.length host <= 253) "the host is over 253 bytes" in
    Ok host

let parse_port ~scheme = function
  | "" -> Ok (default_port scheme)
  | p
    when String.length p <= 5
         && String.for_all (function '0' .. '9' -> true | _ -> false) p -> (
      match int_of_string p with
        | p when p >= 1 && p <= 65535 -> Ok p
        | _ -> Error "the port is not 1 to 65535")
  | _ -> Error "the port is not a number"

let split_at s i =
  (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))

let after_userinfo s =
  match String.rindex_opt s '@' with Some i -> snd (split_at s i) | None -> s

let parse_web ~scheme rest =
  let authority =
    match
      List.filter_map (fun c -> String.index_opt rest c) ['/'; '?'; '#']
    with
      | [] -> rest
      | l -> String.sub rest 0 (List.fold_left min max_int l)
  in
  let authority = after_userinfo authority in
  let host, port =
    let colon =
      if String.length authority > 0 && authority.[0] = '[' then (
        match String.index_opt authority ']' with
          | Some e when e + 1 < String.length authority -> Some (e + 1)
          | _ -> None)
      else String.rindex_opt authority ':'
    in
    match colon with
      | Some i when authority.[i] = ':' -> split_at authority i
      | _ -> (authority, "")
  in
  let* host = parse_host host in
  let* port = parse_port ~scheme port in
  Ok (Web { scheme; host; port })

let is_java_identifier s =
  s <> ""
  && (match s.[0] with 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false)
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false)
       s

(* Chrome exports an app as [android://<hash>@<package>/]. *)
let parse_android rest =
  let rest = after_userinfo rest in
  let package =
    match String.index_opt rest '/' with
      | Some i -> String.sub rest 0 i
      | None -> rest
  in
  if List.for_all is_java_identifier (String.split_on_char '.' package) then
    Ok (Android package)
  else Error "not an Android package name"

(* §4.1 *)
let parse s =
  let s = String.trim s in
  let sep = "://" in
  let rec find i =
    if i + 3 > String.length s then None
    else if String.sub s i 3 = sep then Some i
    else find (i + 1)
  in
  match find 0 with
    | None -> Error "not a URL"
    | Some i -> (
        let rest = String.sub s (i + 3) (String.length s - i - 3) in
        match String.lowercase_ascii (String.sub s 0 i) with
          | ("http" | "https") as scheme -> parse_web ~scheme rest
          | "android" -> parse_android rest
          | _ -> Error "not an http, https or android site")

let render = function
  | Web { scheme; host; port } ->
      scheme ^ "://" ^ host
      ^ if port = default_port scheme then "" else ":" ^ string_of_int port
  | Android package -> "android://" ^ package

let site_of_string s = Result.map render (parse s)
let is_site s = site_of_string s = Ok s

(* §4.2 *)
let matches ~site ~origin =
  match (parse site, parse origin) with
    | Ok (Web s), Ok (Web o) ->
        s.port = o.port
        && (not (s.scheme = "https" && o.scheme = "http"))
        && (s.host = o.host
           || String.contains s.host '.'
              && String.ends_with ~suffix:("." ^ s.host) o.host)
    | Ok (Android a), Ok (Android b) -> a = b
    | _ -> false

type login = {
  title : string;
  urls : site list;
  username : string;
  password : string;
  notes : string;
  totp : string;
  modified : int;
  unknown : (string * Yojson.Safe.t) list;
}

type passkey = {
  rp_id : string;
  credential_id : string;
  user_handle : string;
  user_name : string;
  user_display_name : string;
  algorithm : int;
  private_key : string;
  login : string;
  created : int;
  modified : int;
  unknown : (string * Yojson.Safe.t) list;
}

type t = Login of login | Passkey of passkey

let between ~min ~max s = String.length s >= min && String.length s <= max
let is_link s = s = "" || Fold.is_record_id s

(* §2: every rule a login keeps; no reason names a value. *)
let check_login (l : login) =
  let* () = check (between ~min:1 ~max:256 l.title) "title is 1 to 256 bytes" in
  let* () = check (List.length l.urls <= 32) "urls holds at most 32 sites" in
  let* () = check (List.for_all is_site l.urls) "a url is not a site (§4.1)" in
  let* () =
    check (between ~min:1 ~max:1024 l.password) "password is 1 to 1024 bytes"
  in
  let* () = check (String.length l.notes <= 65536) "notes is at most 64 KiB" in
  let* () = check (is_link l.totp) "totp is neither empty nor a record id" in
  Ok l

let is_rp_id s =
  s <> "" && (not (String.contains s ':')) && is_site ("https://" ^ s)

(* §7.1 *)
let check_passkey (k : passkey) =
  let* () =
    check (is_rp_id k.rp_id) "rpId is not a lower-case A-label domain"
  in
  let* () =
    check (String.length k.credential_id = 32) "credentialId is not 32 bytes"
  in
  let* () =
    check (between ~min:1 ~max:64 k.user_handle) "userHandle is 1 to 64 bytes"
  in
  let* () =
    check (String.length k.user_name <= 256) "userName is at most 256 bytes"
  in
  let* () =
    check
      (String.length k.user_display_name <= 256)
      "userDisplayName is at most 256 bytes"
  in
  let* () = check (k.algorithm = -7) "algorithm is not -7" in
  let* () =
    check (String.length k.private_key = 32) "privateKey is not 32 bytes"
  in
  let* () = check (is_link k.login) "login is neither empty nor a record id" in
  Ok k

let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let login_keys =
  ["kind"; "title"; "urls"; "username"; "password"; "notes"; "totp"; "modified"]

let passkey_keys =
  [
    "kind";
    "rpId";
    "credentialId";
    "userHandle";
    "userName";
    "userDisplayName";
    "algorithm";
    "privateKey";
    "login";
    "created";
    "modified";
  ]

let str members k =
  match List.assoc_opt k members with
    | Some (`String v) -> Ok v
    | _ -> Error (k ^ " is missing or not a string")

let int members k =
  match List.assoc_opt k members with
    | Some (`Int v) -> Ok v
    | _ -> Error (k ^ " is missing or not an integer")

let strings members k =
  let wrong = Error (k ^ " is missing or not an array of strings") in
  match List.assoc_opt k members with
    | Some (`List l) ->
        List.fold_right
          (fun v acc ->
            match (v, acc) with
              | `String v, Ok acc -> Ok (v :: acc)
              | _ -> wrong)
          l (Ok [])
    | _ -> wrong

let binary members k =
  let* v = str members k in
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet v with
    | Ok d when b64 d = v -> Ok d
    | _ -> Error (k ^ " is not base64url without padding")

let unknown ~known members =
  List.filter (fun (k, _) -> not (List.mem k known)) members

let login_of members =
  let* title = str members "title" in
  let* urls = strings members "urls" in
  let* username = str members "username" in
  let* password = str members "password" in
  let* notes = str members "notes" in
  let* totp = str members "totp" in
  let* modified = int members "modified" in
  check_login
    {
      title;
      urls;
      username;
      password;
      notes;
      totp;
      modified;
      unknown = unknown ~known:login_keys members;
    }

let passkey_of members =
  let* rp_id = str members "rpId" in
  let* credential_id = binary members "credentialId" in
  let* user_handle = binary members "userHandle" in
  let* user_name = str members "userName" in
  let* user_display_name = str members "userDisplayName" in
  let* algorithm = int members "algorithm" in
  let* private_key = binary members "privateKey" in
  let* login = str members "login" in
  let* created = int members "created" in
  let* modified = int members "modified" in
  check_passkey
    {
      rp_id;
      credential_id;
      user_handle;
      user_name;
      user_display_name;
      algorithm;
      private_key;
      login;
      created;
      modified;
      unknown = unknown ~known:passkey_keys members;
    }

(* A parser's message quotes the text it stopped at, which may be a password. *)
let of_string s =
  if not (String.is_valid_utf_8 s) then Error "not UTF-8"
  else (
    match Yojson.Safe.from_string s with
      | exception Yojson.Json_error _ -> Error "not JSON"
      | `Assoc members -> (
          match List.assoc_opt "kind" members with
            | Some (`String "login") ->
                Result.map (fun l -> Login l) (login_of members)
            | Some (`String "passkey") ->
                Result.map (fun k -> Passkey k) (passkey_of members)
            | _ -> Error "kind is neither login nor passkey")
      | _ -> Error "not a JSON object")

let to_json = function
  | Login l ->
      `Assoc
        ([
           ("kind", `String "login");
           ("title", `String l.title);
           ("urls", `List (List.map (fun u -> `String u) l.urls));
           ("username", `String l.username);
           ("password", `String l.password);
           ("notes", `String l.notes);
           ("totp", `String l.totp);
           ("modified", `Int l.modified);
         ]
        @ l.unknown)
  | Passkey k ->
      `Assoc
        ([
           ("kind", `String "passkey");
           ("rpId", `String k.rp_id);
           ("credentialId", `String (b64 k.credential_id));
           ("userHandle", `String (b64 k.user_handle));
           ("userName", `String k.user_name);
           ("userDisplayName", `String k.user_display_name);
           ("algorithm", `Int k.algorithm);
           ("privateKey", `String (b64 k.private_key));
           ("login", `String k.login);
           ("created", `Int k.created);
           ("modified", `Int k.modified);
         ]
        @ k.unknown)

(* §2 *)
let to_string t =
  let json = Yojson.Safe.to_string (to_json t) in
  json ^ String.make ((256 - (String.length json mod 256)) mod 256) ' '

(* §3 *)
let key_fields = function
  | Login l -> "login\000" ^ l.password
  | Passkey k ->
      "passkey\000" ^ b64 k.credential_id ^ "\000" ^ b64 k.private_key

let modified = function Login l -> l.modified | Passkey k -> k.modified

let alphanumeric =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

(* §5 *)
let generate ~length ~symbols =
  if length < 8 || length > 128 then Error "length is 8 to 128"
  else (
    let alphabet = alphanumeric ^ if symbols then "!#%+-.=?@_~" else "" in
    let size = String.length alphabet in
    let limit = 256 - (256 mod size) in
    let out = Buffer.create length in
    while Buffer.length out < length do
      String.iter
        (fun c ->
          let b = Char.code c in
          if b < limit && Buffer.length out < length then
            Buffer.add_char out alphabet.[b mod size])
        (Tsync_core.Ids.urandom length)
    done;
    Ok (Buffer.contents out))

type row = {
  line : int;
  title : string;
  urls : site list;
  username : string;
  password : string;
  notes : string;
  otpauth : string;
}

type csv_row = { start : int; fields : string list }

(* RFC 4180, LF line ends accepted too; [start] is the physical line a row
   starts on. *)
let parse_csv text =
  let bom = "\xef\xbb\xbf" in
  let text =
    if String.starts_with ~prefix:bom text then
      String.sub text 3 (String.length text - 3)
    else text
  in
  let n = String.length text in
  let rows = ref [] and fields = ref [] and field = Buffer.create 64 in
  let line = ref 1 and start = ref 1 in
  let end_field () =
    fields := Buffer.contents field :: !fields;
    Buffer.clear field
  in
  let end_row () =
    end_field ();
    rows := { start = !start; fields = List.rev !fields } :: !rows;
    fields := [];
    incr line;
    start := !line
  in
  let rec field_start i =
    if i < n && text.[i] = '"' then quoted (i + 1) else unquoted i
  and unquoted i =
    if i = n then (
      if !fields <> [] || Buffer.length field > 0 then end_row ();
      Ok (List.rev !rows))
    else (
      match text.[i] with
        | ',' ->
            end_field ();
            field_start (i + 1)
        | '\n' ->
            end_row ();
            field_start (i + 1)
        | '\r' when i + 1 < n && text.[i + 1] = '\n' ->
            end_row ();
            field_start (i + 2)
        | c ->
            Buffer.add_char field c;
            unquoted (i + 1))
  and quoted i =
    if i = n then
      Error (Printf.sprintf "the quoted field of line %d is not closed" !start)
    else (
      match text.[i] with
        | '"' when i + 1 < n && text.[i + 1] = '"' ->
            Buffer.add_char field '"';
            quoted (i + 2)
        | '"' -> unquoted (i + 1)
        | c ->
            if c = '\n' then incr line;
            Buffer.add_char field c;
            quoted (i + 1))
  in
  field_start 0

let host_of site =
  match parse site with
    | Ok (Web { host; _ }) -> host
    | Ok (Android package) -> package
    | Error _ -> ""

(* §10.1 *)
let import_csv text =
  let* rows = parse_csv text in
  let rows = List.filter (fun r -> r.fields <> [""]) rows in
  match rows with
    | [] -> Error "the file has no header row"
    | header :: rows -> (
        let names =
          List.map
            (fun h -> String.lowercase_ascii (String.trim h))
            header.fields
        in
        let column aliases =
          let rec find i = function
            | [] -> None
            | name :: _ when List.mem name aliases -> Some i
            | _ :: rest -> find (i + 1) rest
          in
          find 0 names
        in
        match column ["password"; "login_password"] with
          | None -> Error "the file has no password column"
          | Some password_column ->
              let title_column = column ["name"; "title"]
              and url_column = column ["url"; "login_uri"; "website"]
              and username_column = column ["username"; "login_username"]
              and notes_column = column ["note"; "notes"]
              and otpauth_column = column ["otpauth"; "login_totp"] in
              let row_of { start; fields } =
                let get = function
                  | None -> ""
                  | Some i -> Option.value ~default:"" (List.nth_opt fields i)
                in
                let password = get (Some password_column) in
                let* () = check (password <> "") "the password is empty" in
                let* urls =
                  match String.trim (get url_column) with
                    | "" -> Ok []
                    | url -> (
                        match site_of_string url with
                          | Ok site -> Ok [site]
                          | Error e -> Error ("the url is refused: " ^ e))
                in
                let title =
                  match (get title_column, urls) with
                    | "", site :: _ -> host_of site
                    | title, _ -> title
                in
                let* () = check (title <> "") "no title and no site" in
                let* login =
                  check_login
                    {
                      title;
                      urls;
                      username = get username_column;
                      password;
                      notes = get notes_column;
                      totp = "";
                      modified = 0;
                      unknown = [];
                    }
                in
                Ok
                  {
                    line = start;
                    title = login.title;
                    urls = login.urls;
                    username = login.username;
                    password = login.password;
                    notes = login.notes;
                    otpauth = String.trim (get otpauth_column);
                  }
              in
              let kept, skipped =
                List.fold_left
                  (fun (kept, skipped) r ->
                    match row_of r with
                      | Ok row -> (row :: kept, skipped)
                      | Error why -> (kept, (r.start, why) :: skipped))
                  ([], []) rows
              in
              Ok (List.rev kept, List.rev skipped))

let csv_field s =
  if String.exists (function ',' | '"' | '\n' | '\r' -> true | _ -> false) s
  then "\"" ^ String.concat "\"\"" (String.split_on_char '"' s) ^ "\""
  else s

(* §10 *)
let export_csv ~otpauth logins =
  let line fields = String.concat "," (List.map csv_field fields) ^ "\r\n" in
  String.concat ""
    (line ["name"; "url"; "username"; "password"; "note"; "otpauth"]
    :: List.map
         (fun (l : login) ->
           line
             [
               l.title;
               (match l.urls with site :: _ -> site | [] -> "");
               l.username;
               l.password;
               l.notes;
               otpauth l;
             ])
         logins)
