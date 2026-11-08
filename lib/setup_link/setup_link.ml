open Tsync_core
module Crypto = Tsync_vault.Crypto

type backend = { name : string; url : string; secret : string }
type domain = { name : Domain_name.t; backends : backend list }

type entry =
  | Joinable of domain
  | Unusable of { name : string; reason : string }

type payload = { from : string; entries : entry list }
type vault_look = { color : string; icon : string option }

type about = {
  name : Domain_name.t;
  extensions : string list;
  vault : vault_look option;
}

type link = { base : string; token : string; key : string }

type stored = {
  domain : Domain_name.t;
  expires : float;
  sealed : string;
  about : about list;
}

let default_expiry = 7. *. 86400.
let max_sealed = 64 * 1024
let max_domains = 16
let key_size = 32
let not_a_link = "This is not a tsync setup link"
let damaged = "This setup link is damaged; copy it whole"

let url64 s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let of_url64 s =
  Result.to_option
    (Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s)

let link_to_string l =
  Printf.sprintf "%s/join/%s#%s" l.base l.token (url64 l.key)

let is_token s =
  let n = String.length s in
  n >= 32 && n <= 128
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

(* §2: https, or http to a loopback host. *)
let scheme_allowed base =
  let host_of rest =
    let stop =
      Option.value ~default:(String.length rest) (String.index_opt rest '/')
    in
    let authority = String.sub rest 0 stop in
    if String.starts_with ~prefix:"[" authority then
      String.sub authority 0
        (Option.value ~default:(String.length authority)
           (Option.map succ (String.index_opt authority ']')))
    else
      String.sub authority 0
        (Option.value ~default:stop (String.index_opt authority ':'))
  in
  if String.starts_with ~prefix:"https://" base then true
  else if String.starts_with ~prefix:"http://" base then (
    let host = host_of (String.sub base 7 (String.length base - 7)) in
    host = "localhost" || host = "[::1]"
    || String.starts_with ~prefix:"127." host)
  else false

let rec last_join s i =
  if i < 0 then None
  else if String.sub s i 6 = "/join/" then Some i
  else last_join s (i - 1)

let link_of_string s =
  let s = String.trim s in
  match String.index_opt s '#' with
    | None -> Error not_a_link
    | Some hash -> (
        let url = String.sub s 0 hash
        and fragment = String.sub s (hash + 1) (String.length s - hash - 1) in
        match last_join url (String.length url - 6) with
          | None -> Error not_a_link
          | Some j -> (
              let base = String.sub url 0 j
              and token = String.sub url (j + 6) (String.length url - j - 6) in
              match of_url64 fragment with
                | Some key
                  when String.length key = key_size
                       && is_token token && scheme_allowed base ->
                    Ok { base; token; key }
                | _ -> Error not_a_link))

let ad token = "tsync-setup/" ^ token

let backend_json (b : backend) =
  `Assoc
    [
      ("type", `String "http-proxy");
      ("name", `String b.name);
      ("url", `String b.url);
      ("secret", `String b.secret);
    ]

let payload_json ~from domains =
  `Assoc
    [
      ("v", `Int 1);
      ("from", `String from);
      ( "domains",
        `List
          (List.map
             (fun (d : domain) ->
               `Assoc
                 [
                   ("name", `String (Domain_name.to_string d.name));
                   ("backends", `List (List.map backend_json d.backends));
                 ])
             domains) );
    ]

let create ~base ~expires ~from ~about domains =
  let token = Ids.token () and key = Ids.urandom key_size in
  let nonce = Ids.urandom Crypto.nonce_size in
  let plain = Yojson.Safe.to_string (payload_json ~from domains) in
  let sealed = nonce ^ Crypto.seal ~key ~nonce ~ad:(ad token) plain in
  ( { base; token; key },
    { domain = (List.hd domains).name; expires; sealed; about } )

let about_json (a : about) =
  `Assoc
    ([
       ("name", `String (Domain_name.to_string a.name));
       ("extensions", `List (List.map (fun e -> `String e) a.extensions));
     ]
    @
      match a.vault with
      | None -> []
      | Some v ->
          [
            ( "vault",
              `Assoc
                (("color", `String v.color)
                ::
                  (match v.icon with
                  | Some png -> [("icon", `String (Base64.encode_string png))]
                  | None -> [])) );
          ])

let stored_to_string s =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("v", `Int 1);
         ("expires", `Int (int_of_float s.expires));
         ("domain", `String (Domain_name.to_string s.domain));
         ("type", `String "setup");
         ("sealed", `String (url64 s.sealed));
         ("about", `List (List.map about_json s.about));
       ])

let member k = function `Assoc l -> List.assoc_opt k l | _ -> None
let str k j = match member k j with Some (`String s) -> Some s | _ -> None

let strings k j =
  match member k j with
    | Some (`List l) ->
        List.filter_map (function `String s -> Some s | _ -> None) l
    | _ -> []

(* §4: a look that does not check is dropped, never the entry. *)
let vault_of j =
  Option.bind (member "vault" j) (fun v ->
      match Option.map Tsync_vault.Appearance.check_color (str "color" v) with
        | Some (Ok color) -> (
            match str "icon" v with
              | None -> Some { color; icon = None }
              | Some b64 -> (
                  match
                    Option.map Tsync_vault.Appearance.check_icon
                      (Result.to_option (Base64.decode b64))
                  with
                    | Some (Ok icon) -> Some { color; icon = Some icon }
                    | _ -> None))
        | _ -> None)

let about_of j =
  Option.bind (str "name" j) (fun n ->
      Result.to_option (Domain_name.of_string n)
      |> Option.map (fun name ->
          { name; extensions = strings "extensions" j; vault = vault_of j }))

let stored_of_json j =
  let ( let* ) o f = match o with Some x -> f x | None -> Error "invalid" in
  let* () = if member "v" j = Some (`Int 1) then Some () else None in
  let* () = if str "type" j = Some "setup" then Some () else None in
  let* domain =
    Option.bind (str "domain" j) (fun d ->
        Result.to_option (Domain_name.of_string d))
  in
  let* sealed = Option.bind (str "sealed" j) of_url64 in
  let* () =
    let n = String.length sealed in
    if n >= Crypto.nonce_size + Crypto.tag_size && n <= max_sealed then Some ()
    else None
  in
  let* about =
    match member "about" j with
      | None -> Some []
      | Some (`List l) when List.length l <= max_domains ->
          let parsed = List.filter_map about_of l in
          if List.length parsed = List.length l then Some parsed else None
      | Some _ -> None
  in
  let expires =
    match member "expires" j with
      | Some (`Int n) -> float_of_int n
      | Some (`Float x) -> x
      | _ -> 0.
  in
  Ok { domain; expires; sealed; about }

let stored_of_string body =
  match Yojson.Safe.from_string body with
    | j -> stored_of_json j
    | exception Yojson.Json_error e -> Error e

let fetch link =
  let r =
    Tsync_http.Client.request
      (Tsync_http.Client.endpoint link.base)
      ~meth:"GET"
      ("/join/" ^ link.token ^ "?json=1")
  in
  let body = Bigstring.to_string r.body in
  match r.status with
    | 200 -> Result.map_error (fun _ -> damaged) (stored_of_string body)
    | 404 -> Error "This setup link was revoked, or never existed"
    | 410 -> (
        match
          Option.bind
            (try Some (Yojson.Safe.from_string body)
             with Yojson.Json_error _ -> None)
            (member "expires")
        with
          | Some (`Int n) ->
              Error
                ("This setup link expired on " ^ Narrate.date (float_of_int n))
          | _ -> Error "This setup link expired")
    | s ->
        Error
          (Printf.sprintf "%s answered HTTP %d: %s" link.base s
             (Tsync_http.Client.excerpt r.body))

let backend_of j =
  match (str "type" j, str "url" j, str "secret" j) with
    | Some "http-proxy", Some url, Some secret ->
        Ok { name = Option.value ~default:"server" (str "name" j); url; secret }
    | Some t, _, _ ->
        Error (Printf.sprintf "its %s backend cannot be held here" t)
    | None, _, _ -> Error "a backend has no type"

let entry_of j =
  let raw = Option.value ~default:"?" (str "name" j) in
  let unusable reason = Unusable { name = raw; reason } in
  match Domain_name.of_string raw with
    | Error _ -> unusable "not a valid domain name"
    | Ok name -> (
        let backends =
          match member "backends" j with Some (`List l) -> l | _ -> []
        in
        match List.map backend_of backends with
          | [] -> unusable "it has no backend"
          | results -> (
              match
                List.find_map
                  (function Error e -> Some e | Ok _ -> None)
                  results
              with
                | Some reason -> unusable reason
                | None ->
                    Joinable
                      {
                        name;
                        backends = List.filter_map Result.to_option results;
                      }))

let open_ link stored =
  let n = Crypto.nonce_size in
  let nonce = String.sub stored.sealed 0 n
  and box = String.sub stored.sealed n (String.length stored.sealed - n) in
  match Crypto.open_ ~key:link.key ~nonce ~ad:(ad link.token) box with
    | None -> Error damaged
    | Some plain -> (
        match Yojson.Safe.from_string plain with
          | exception Yojson.Json_error _ -> Error damaged
          | j when member "v" j = Some (`Int 1) ->
              let domains =
                match member "domains" j with Some (`List l) -> l | _ -> []
              in
              Ok
                {
                  from = Option.value ~default:"" (str "from" j);
                  entries = List.map entry_of domains;
                }
          | _ -> Error damaged)
