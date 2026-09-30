open Tsync_core
open Tsync_http

let scope = "https://www.googleapis.com/auth/devstorage.full_control"
let default_token_uri = "https://oauth2.googleapis.com/token"
let token_margin = 60.

type state = {
  email : string;
  key : Mirage_crypto_pk.Rsa.priv;
  token_uri : string;
  endpoint : Client.endpoint;
  cached : (string * float) option Atomic.t;  (** token, monotonic expiry *)
  minting : Rt.Fmutex.t;
}

let invalid fmt = Fail.raise_ Fail.Invalid fmt

let create text =
  let fields =
    match Yojson.Safe.from_string text with
      | `Assoc l -> l
      | _ | (exception _) ->
          invalid "gcs: service account key is not valid JSON"
  in
  let str k =
    match List.assoc_opt k fields with
      | Some (`String s) -> s
      | _ -> invalid "gcs: service account key missing string field: %s" k
  in
  let email = str "client_email" in
  let key =
    match X509.Private_key.decode_pem (str "private_key") with
      | Ok (`RSA k) -> k
      | Ok _ -> invalid "gcs: service account key is not an RSA key"
      | Error (`Msg m) -> invalid "gcs: cannot parse private key: %s" m
  in
  let token_uri =
    match List.assoc_opt "token_uri" fields with
      | Some (`String u) when u <> "" -> u
      | _ -> default_token_uri
  in
  let base, path =
    match String.index_from_opt token_uri 8 '/' with
      | Some i ->
          ( String.sub token_uri 0 i,
            String.sub token_uri i (String.length token_uri - i) )
      | None -> (token_uri, "/")
  in
  {
    email;
    key;
    token_uri;
    endpoint = Client.endpoint ~max_connections:2 base;
    cached = Atomic.make None;
    minting = Rt.Fmutex.create ();
  }
  |> fun t -> (t, path)

let b64 s = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(* The claims are compared across hosts, so [iat] is the wall clock; the
   signature is deterministic and needs no random source. *)
let jwt (t : state) =
  let now = int_of_float (Unix.gettimeofday ()) in
  let header = b64 {|{"alg":"RS256","typ":"JWT"}|} in
  let claims =
    b64
      (Yojson.Safe.to_string
         (`Assoc
            [
              ("iss", `String t.email);
              ("scope", `String scope);
              ("aud", `String t.token_uri);
              ("iat", `Int now);
              ("exp", `Int (now + 3600));
            ]))
  in
  let input = header ^ "." ^ claims in
  let signature =
    Mirage_crypto_pk.Rsa.PKCS1.sign ~mask:`No ~hash:`SHA256 ~key:t.key
      (`Message input)
  in
  input ^ "." ^ b64 signature

let form_escape s =
  String.concat ""
    (List.map
       (fun c ->
         match c with
           | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' ->
               String.make 1 c
           | c -> Printf.sprintf "%%%02X" (Char.code c))
       (List.of_seq (String.to_seq s)))

let mint ((t : state), path) =
  let body =
    "grant_type="
    ^ form_escape "urn:ietf:params:oauth:grant-type:jwt-bearer"
    ^ "&assertion=" ^ jwt t
  in
  let r =
    Client.request t.endpoint ~meth:"POST" ~body
      ~headers:(fun () ->
        [("content-type", "application/x-www-form-urlencoded")])
      path
  in
  let json = try Yojson.Safe.from_string r.body with _ -> `Null in
  let field k = match json with `Assoc l -> List.assoc_opt k l | _ -> None in
  match r.status with
    | s when s >= 200 && s < 300 -> (
        match field "access_token" with
          | Some (`String tok) ->
              let ttl =
                match field "expires_in" with
                  | Some (`Int n) -> float_of_int n
                  | Some (`Float f) -> f
                  | _ -> 3600.
              in
              (tok, Rt.now () +. ttl -. token_margin)
          | _ ->
              Fail.raise_ Fail.Link
                "gcs: the token answer carries no access_token")
    | 429 | 503 ->
        Fail.raise_ Fail.Load "gcs: token endpoint busy (HTTP %d)" r.status
    | (400 | 401 | 403)
      when List.mem
             (match field "error" with Some (`String e) -> e | _ -> "")
             [
               "invalid_grant";
               "invalid_client";
               "unauthorized_client";
               "access_denied";
             ] ->
        Fail.raise_ Fail.Denied
          "gcs: the service account grant was refused (the key was revoked or \
           disabled, or this clock is too far off): %s"
          (Client.excerpt r.body)
    | s when s >= 500 -> Fail.raise_ Fail.Link "gcs: token endpoint HTTP %d" s
    | s ->
        Fail.raise_ Fail.Refused "gcs: token endpoint HTTP %d: %s" s
          (Client.excerpt r.body)

let fresh (t, _) =
  match Atomic.get t.cached with
    | Some (tok, until) when Rt.now () < until -> Some tok
    | _ -> None

let token ((t, _) as a) =
  match fresh a with
    | Some tok -> tok
    | None ->
        Rt.Fmutex.with_lock t.minting (fun () ->
            match fresh a with
              | Some tok -> tok
              | None ->
                  let tok, until = mint a in
                  Atomic.set t.cached (Some (tok, until));
                  tok)

let invalidate (t, _) tok =
  match Atomic.get t.cached with
    | Some (c, _) as cur when c = tok ->
        ignore (Atomic.compare_and_set t.cached cur None)
    | _ -> ()

type t = state * string
