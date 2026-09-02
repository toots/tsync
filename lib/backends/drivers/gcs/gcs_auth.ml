(* Fetching a token is one POST, and all this reads of the answer is the status
   and the body -- so that is the whole of what it asks for. *)
module type POST = sig
  type 'a io

  val post :
    headers:Cohttp.Header.t -> body:string -> Uri.t -> (int * string) io
end

module Over
    (Io : Io.S)
    (Post : POST with type 'a io := 'a Io.t)
    (Lock : Lock.S with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  (* OAuth 2.0 for the GCS backend: turn a service-account JSON key into a
     short-lived bearer token (RFC 7523 JWT-bearer flow), cached and refreshed. *)

  type t = {
    client_email : string;
    private_key : Mirage_crypto_pk.Rsa.priv;
    token_uri : string;
    scope : string;
    mutable cached : (string * float) option; (* token, absolute expiry time *)
    refresh_lock : Lock.mutex;
  }

  let b64url s =
    Base64.encode_string ~alphabet:Base64.uri_safe_alphabet ~pad:false s

  let member_string j key =
    match Yojson.Safe.Util.member key j with
      | `String s -> s
      | _ -> failwith ("gcs: service account key missing string field: " ^ key)

  (* The file downloaded from GCP. *)
  let of_service_account_json json =
    let j =
      try Yojson.Safe.from_string json
      with _ -> failwith "gcs: service account key is not valid JSON"
    in
    let client_email = member_string j "client_email" in
    let pem = member_string j "private_key" in
    let token_uri =
      match Yojson.Safe.Util.member "token_uri" j with
        | `String s -> s
        | _ -> "https://oauth2.googleapis.com/token"
    in
    let private_key =
      match X509.Private_key.decode_pem pem with
        | Ok (`RSA k) -> k
        | Ok _ -> failwith "gcs: service account key is not an RSA key"
        | Error (`Msg m) -> failwith ("gcs: cannot parse private key: " ^ m)
    in
    {
      client_email;
      private_key;
      token_uri;
      (* [full_control] rather than [read_write] for one operation: the XML API's
         bulk delete refuses a [read_write] token outright — "Provided scope(s) are
         not authorized" — where the JSON API's single delete accepts it, and bulk
         delete is what a collection does a thousand keys at a time.

         A scope is a ceiling on the token, not a grant: what this service account
         may actually do stays whatever its IAM role says, which is
         [roles/storage.objectUser] — objects only, no bucket or IAM policy. So the
         wider scope buys the delete and grants nothing the role does not already
         allow. *)
      scope = "https://www.googleapis.com/auth/devstorage.full_control";
      cached = None;
      refresh_lock = Lock.mutex ();
    }

  (* PKCS#1 v1.5 is deterministic, so [`No] masking needs no RNG: the JWT is
     signed before any TLS connection exists to seed one, and blinding only guards
     local timing channels. *)
  let make_jwt t =
    let now = int_of_float (Unix.gettimeofday ()) in
    let header = `Assoc [("alg", `String "RS256"); ("typ", `String "JWT")] in
    let claims =
      `Assoc
        [
          ("iss", `String t.client_email);
          ("scope", `String t.scope);
          ("aud", `String t.token_uri);
          ("iat", `Int now);
          ("exp", `Int (now + 3600));
        ]
    in
    let enc j = b64url (Yojson.Safe.to_string j) in
    let signing_input = enc header ^ "." ^ enc claims in
    let signature =
      Mirage_crypto_pk.Rsa.PKCS1.sign ~mask:`No ~hash:`SHA256 ~key:t.private_key
        (`Message signing_input)
    in
    signing_input ^ "." ^ b64url signature

  let request_token t =
    let body =
      Uri.encoded_of_query
        [
          ("grant_type", ["urn:ietf:params:oauth:grant-type:jwt-bearer"]);
          ("assertion", [make_jwt t]);
        ]
    in
    let headers =
      Cohttp.Header.of_list
        [("Content-Type", "application/x-www-form-urlencoded")]
    in
    let* code, s = Post.post ~headers ~body (Uri.of_string t.token_uri) in
    if code < 200 || code >= 300 then
      Io.fail (Failure (Printf.sprintf "gcs oauth: HTTP %d: %s" code s))
    else begin
      let j = Yojson.Safe.from_string s in
      let token = member_string j "access_token" in
      let expires_in =
        match Yojson.Safe.Util.member "expires_in" j with
          | `Int n -> float_of_int n
          | `Float f -> f
          | _ -> 3600.
      in
      Io.return (token, Unix.gettimeofday () +. expires_in)
    end

  (* A minute early, to absorb clock skew. *)
  let refresh_margin = 60.

  let fresh t =
    match t.cached with
      | Some (tok, exp) when Unix.gettimeofday () < exp -. refresh_margin ->
          Some tok
      | _ -> None

  (* Concurrent callers on a cold cache share one refresh: the mutex serializes
     them and the re-check inside returns what the first waiter fetched. *)
  let token t =
    match fresh t with
      | Some tok -> Io.return tok
      | None ->
          Lock.with_lock t.refresh_lock (fun () ->
              match fresh t with
                | Some tok -> Io.return tok
                | None ->
                    let* tok, exp = request_token t in
                    t.cached <- Some (tok, exp);
                    Io.return tok)
end
