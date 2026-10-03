open Tsync_core
module Client = Tsync_http.Client
module Codec = Tsync_http.Codec
module Xml = Tsync_store.Bucket_xml
module Object_store = Tsync_store.Object_store

let valid_region r =
  r <> ""
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
       r

let fields =
  Field_spec.
    [
      f ~required:true
        ~check:(fun b ->
          if b = "" || String.contains b '/' then Some "invalid bucket name"
          else None)
        "bucket" "Bucket" String;
      f ~default:"us-east-1"
        ~check:(fun r ->
          if r = "" || valid_region r then None
          else Some "lowercase letters, digits and dashes")
        "region" "Region" String;
      f ~check:(http_url ~bare_host:true) "endpoint" "Endpoint" String;
      f ~required:true "accessKeyId" "Access key id" String;
      f ~secret:true ~required:true "secretAccessKey" "Secret access key" String;
      f ~default:"false" "unsignedPayload" "Unsigned payload" Bool;
      f "shareUrl" "Share URL" String;
      f ~default:"true" "etagIsMd5" "ETags are MD5s" Bool;
    ]

(* §2: the same string is signed and sent; [/] separates a key's segments. *)
let uri_encode ?(keep_slash = false) s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~') as c ->
          Buffer.add_char b c
      | '/' when keep_slash -> Buffer.add_char b '/'
      | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let canonical_query pairs =
  String.concat "&"
    (List.sort compare
       (List.map (fun (k, v) -> uri_encode k ^ "=" ^ uri_encode v) pairs))

let hex_sha256 s = Digestif.SHA256.(to_hex (digest_string s))
let empty_payload = hex_sha256 ""
let hmac key data = Digestif.SHA256.(to_raw_string (hmac_string ~key data))

let amz_date t =
  let g = Unix.gmtime t in
  Printf.sprintf "%04d%02d%02dT%02d%02d%02dZ" (g.tm_year + 1900) (g.tm_mon + 1)
    g.tm_mday g.tm_hour g.tm_min g.tm_sec

type credentials = { access_key : string; secret : string; region : string }

(* §3.1. [headers] are every header sent, the host included. *)
let authorization c ~time ~meth ~path ~query ~headers ~payload_hash =
  let stamp = amz_date time in
  let date = String.sub stamp 0 8 in
  let headers =
    List.sort compare
      (List.map
         (fun (k, v) -> (String.lowercase_ascii k, String.trim v))
         headers)
  in
  let signed = String.concat ";" (List.map fst headers) in
  let canonical =
    String.concat "\n"
      [
        meth;
        path;
        query;
        String.concat "" (List.map (fun (k, v) -> k ^ ":" ^ v ^ "\n") headers);
        signed;
        payload_hash;
      ]
  in
  let scope = Printf.sprintf "%s/%s/s3/aws4_request" date c.region in
  let to_sign =
    String.concat "\n" ["AWS4-HMAC-SHA256"; stamp; scope; hex_sha256 canonical]
  in
  (* ponytail: the signing key is derived per request, four HMACs; cache it
     per day if signing ever shows in a profile. *)
  let key =
    List.fold_left hmac ("AWS4" ^ c.secret)
      [date; c.region; "s3"; "aws4_request"]
  in
  Printf.sprintf
    "AWS4-HMAC-SHA256 Credential=%s/%s,SignedHeaders=%s,Signature=%s"
    c.access_key scope signed
    Digestif.SHA256.(to_hex (hmac_string ~key to_sign))

type claims = Unchecked | Honoured | Ignored

type t = {
  api : Client.endpoint;
  bucket : string;
  credentials : credentials;
  unsigned_payload : bool;
  etag_is_md5 : bool;  (** §4.5: an ETag of 32 hex digits is the body's MD5 *)
  domain : Domain_name.t;
  claims : claims Atomic.t;  (** [Honoured] from the start on AWS *)
  replaces : claims Atomic.t;  (** If-Match, likewise *)
}

let success s = s >= 200 && s < 300

let path t = function
  | None -> "/" ^ uri_encode t.bucket
  | Some k ->
      "/" ^ uri_encode t.bucket ^ "/"
      ^ uri_encode ~keep_slash:true (Key.to_string k)

(* Signed per attempt, so a retry is never stale by the ladder's delays. *)
let call t ?(headers = []) ?body ?(payload_hash = empty_payload) ?(query = [])
    ~meth key =
  let path = path t key and query = canonical_query query in
  let target = if query = "" then path else path ^ "?" ^ query in
  Client.request t.api ~meth ?body target ~headers:(fun () ->
      let time = Unix.gettimeofday () in
      let sent =
        ("x-amz-date", amz_date time)
        :: ("x-amz-content-sha256", payload_hash)
        :: headers
      in
      ( "authorization",
        authorization t.credentials ~time ~meth ~path ~query
          ~headers:(("host", Client.authority t.api) :: sent)
          ~payload_hash )
      :: sent)

let error_code body = Xml.field body "Code"

(* §5: the shell's kinds, with the reasons S3 needs said. *)
let fail ~op (r : Client.response) =
  let body = Bigstring.to_string r.body in
  let code = error_code body in
  let header = Codec.header r.headers in
  let retry_after = Option.bind (header "retry-after") float_of_string_opt in
  let f =
    Object_store.status_failure ~op ?retry_after ~body:(Client.excerpt r.body)
      r.status
  in
  (* 4xx codes that say "again", which the status alone reads as a refusal. *)
  let f =
    match code with
      | Some "RequestTimeout" -> { f with kind = Fail.Link }
      | Some "OperationAborted" -> { f with kind = Fail.Load }
      | _ -> f
  in
  let reason =
    match code with
      | Some "RequestTimeTooSkewed" ->
          Some "local clock is off by more than 15 minutes"
      | Some
          ( "PermanentRedirect" | "TemporaryRedirect"
          | "AuthorizationHeaderMalformed" ) ->
          Some "the bucket is in another region or endpoint"
      | _ when r.status = 301 ->
          Some "the bucket is in another region or endpoint"
      | _ -> None
  in
  match reason with
    | None -> raise (Fail.E f)
    | Some reason ->
        let region =
          match header "x-amz-bucket-region" with
            | Some r -> Some r
            | None -> Xml.field body "Region"
        in
        raise
          (Fail.E
             {
               f with
               reason =
                 Printf.sprintf "%s: %s%s" op reason
                   (match region with
                     | Some r -> Printf.sprintf " (region %s)" r
                     | None -> "");
             })

let get_opt t k =
  match call t ~meth:"GET" (Some k) with
    | r when success r.status -> Some r.body
    | { status = 404; _ } -> None
    | r -> fail ~op:"get" r

let put_request t ?(headers = []) k body =
  let payload_hash =
    if t.unsigned_payload then "UNSIGNED-PAYLOAD"
    else Digestif.SHA256.(to_hex (digest_bigstring body))
  in
  call t ~meth:"PUT" ~body ~payload_hash ~headers (Some k)

let claim_retries = 3

let refuses_header header (r : Client.response) =
  r.status = 501
  || (r.status = 400 && Text.contains (Bigstring.to_string r.body) header)

let cannot_claim = refuses_header "If-None-Match"

(* §4.2: a 412 reads the holder back; its own bytes mean its own earlier
   attempt won. *)
let put_if_absent t k body =
  let rec go n =
    match put_request t ~headers:[("if-none-match", "*")] k body with
      | r when success r.status -> Tsync_store.Store.Won
      | { status = 412; _ } -> (
          match get_opt t k with
            | Some held when Bigstring.equal held body -> Won
            | Some held -> Held held
            | None when n > 1 -> go (n - 1)
            | None ->
                Fail.raise_ Fail.Load "s3: %s changed hands during a claim"
                  (Key.to_string k))
      | r when cannot_claim r ->
          Fail.raise_ Fail.Refused "s3: this store cannot claim a name"
      | r -> fail ~op:"put_if_absent" r
  in
  go claim_retries

let get_range t k off len =
  let r =
    call t ~meth:"GET" (Some k)
      ~headers:[("range", Printf.sprintf "bytes=%d-%d" off (off + len - 1))]
  in
  let ranged = Codec.header r.headers "content-range" in
  match r.status with
    (* Some S3-compatible servers (rclone) answer a range with 200 and its
     Content-Range. *)
    | (206 | 200) when r.status = 206 || ranged <> None -> (
        match ranged with
          | Some cr
            when String.starts_with ~prefix:(Printf.sprintf "bytes %d-" off) cr
                 && Bigstring.length r.body <= len ->
              Some r.body
          | _ ->
              Fail.corrupt "s3: %s: a range answer that is not the one asked"
                (Key.to_string k))
    | 200 ->
        let n = Bigstring.length r.body in
        if n - off > len then
          Fail.corrupt "s3: %s: the whole object for a range" (Key.to_string k)
        else if off >= n then Some Bigstring.empty
        else Some (Bigstring.sub r.body ~off ~len:(n - off))
    | 416 -> Some Bigstring.empty
    | 404 -> None
    | _ -> fail ~op:"get_range" r

let unquote s =
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2) else s

(* §4.5: a multipart ETag ([…-n]) is no MD5, and neither is any ETag of a
   store configured otherwise. *)
let checksum t etag =
  if t.etag_is_md5 then Option.bind etag Tsync_store.Checksum.md5_of_hex
  else None

let head_opt t k =
  match call t ~meth:"HEAD" (Some k) with
    | r when success r.status -> (
        let h = Codec.header r.headers in
        match
          ( Option.bind (h "content-length") int_of_string_opt,
            Option.bind (h "last-modified") Codec.parse_http_date,
            h "etag" )
        with
          | Some size, Some last_modified, Some etag ->
              Some
                {
                  Tsync_store.Store.key = k;
                  size;
                  last_modified;
                  etag = Some (unquote etag);
                  checksum = checksum t (Some (unquote etag));
                }
          | _ ->
              Fail.corrupt "s3: %s: a HEAD answer without size, time or tag"
                (Key.to_string k))
    | { status = 404; _ } -> None
    | r -> fail ~op:"head" r

(* §4: S3 answers 204 whether or not the object was there, so its presence is
   asked first; only the status is read, so a HEAD lacking a header the entry
   needs does not fail the delete. *)
let present t k =
  match call t ~meth:"HEAD" (Some k) with
    | r when success r.status -> true
    | { status = 404; _ } -> false
    | r -> fail ~op:"head" r

let delete t k =
  present t k
  &&
    match call t ~meth:"DELETE" (Some k) with
    | r when success r.status -> true
    | { status = 404; _ } -> false
    | r -> fail ~op:"delete" r

let delete_page t keys =
  let unsafe, safe =
    List.partition (fun k -> not (Xml.safe (Key.to_string k))) keys
  in
  List.iter (fun k -> ignore (delete t k)) unsafe;
  if safe <> [] then (
    let body = Xml.delete_body (List.map Key.to_string safe) in
    let r =
      call t ~meth:"POST" ~body:(Bigstring.of_string body)
        ~payload_hash:(hex_sha256 body)
        ~query:[("delete", "")]
        ~headers:
          [
            ("content-type", "application/xml");
            ("content-md5", Base64.encode_string (Digest.string body));
          ]
        None
    in
    if not (success r.status) then fail ~op:"delete_multi" r;
    match
      List.filter
        (fun (code, _) -> code <> "NoSuchKey")
        (Xml.delete_errors (Bigstring.to_string r.body))
    with
      | [] -> ()
      | (code, key) :: _ as refused ->
          let f = Object_store.per_key_failure ~op:"delete_multi" ~code ~key in
          raise
            (Fail.E
               {
                 f with
                 reason =
                   Printf.sprintf "%s (%d keys refused)" f.reason
                     (List.length refused);
               }))

(* A server-side copy may answer 200 with an <Error> body. *)
let copy t src dst =
  let r =
    call t ~meth:"PUT" (Some dst)
      ~headers:[("x-amz-copy-source", path t (Some src))]
  in
  let body = Bigstring.to_string r.body in
  match (r.status, error_code body) with
    | s, None when success s -> ()
    | 404, _ | _, Some "NoSuchKey" ->
        Fail.absent "s3: %s: no such object" (Key.to_string src)
    | s, Some code when success s ->
        raise
          (Fail.E
             (Object_store.per_key_failure ~op:"copy" ~code
                ~key:(Key.to_string src)))
    | _ -> fail ~op:"copy" r

let iso8601 s =
  match Ptime.of_rfc3339 s with
    | Ok (t, _, _) -> Ptime.to_float_s t
    | Error _ -> Fail.corrupt "s3: bad time %S" s

let entry_of_xml t e =
  let get tag =
    match Xml.field e tag with
      | Some v -> v
      | None -> Fail.corrupt "s3: a listed object without %s" tag
  in
  let name = get "Key" in
  {
    Object_store.name;
    size =
      (match int_of_string_opt (get "Size") with
        | Some n -> n
        | None -> Fail.corrupt "s3: bad size for %s" name);
    last_modified = iso8601 (get "LastModified");
    etag = Option.map unquote (Xml.field e "ETag");
    checksum = checksum t (Option.map unquote (Xml.field e "ETag"));
  }

let list_page t ~prefix ~token ~max =
  let query =
    [("list-type", "2"); ("prefix", Key.prefix_to_string prefix)]
    @ (match max with
      | Some m -> [("max-keys", string_of_int (min m 1000))]
      | None -> [])
    @ match token with Some tok -> [("continuation-token", tok)] | None -> []
  in
  match call t ~meth:"GET" ~query None with
    | r when success r.status ->
        let body = Bigstring.to_string r.body in
        ( List.map (entry_of_xml t) (Xml.elements body "Contents"),
          Xml.field body "NextContinuationToken" )
    | r -> fail ~op:"list" r

(* §4.2: re-claiming an immutable object with its own bytes is answered 412 by
   a provider that honours If-None-Match, while one that ignores it rewrites
   the same bytes, harmlessly. The empty chunk is such an object in every
   domain, written first so the claim always finds it. *)
let check_claims t =
  let ignored () =
    Fail.raise_ Fail.Refused
      "s3: this store ignores If-None-Match, so it cannot claim a name"
  in
  match Atomic.get t.claims with
    | Honoured -> ()
    | Ignored -> ignored ()
    | Unchecked -> (
        let k = Key.chunk t.domain Chunk_key.empty in
        let r = put_request t k Bigstring.empty in
        if not (success r.status) then fail ~op:"put" r;
        match
          put_request t ~headers:[("if-none-match", "*")] k Bigstring.empty
        with
          | { status = 412; _ } -> Atomic.set t.claims Honoured
          | r when success r.status ->
              Atomic.set t.claims Ignored;
              ignored ()
          | r -> fail ~op:"put_if_absent" r)

(* §4.2: a provider that honours If-Match answers 412 to a write of the empty
   chunk naming an ETag it cannot have; one that ignores it rewrites the same
   bytes, harmlessly, and is never trusted with a conditional replace. *)
let impossible_etag = "\"" ^ String.make 32 '0' ^ "\""

let check_replaces t =
  let ignored () =
    Fail.raise_ Fail.Refused
      "s3: this store ignores If-Match, so it cannot replace conditionally"
  in
  match Atomic.get t.replaces with
    | Honoured -> ()
    | Ignored -> ignored ()
    | Unchecked -> (
        let k = Key.chunk t.domain Chunk_key.empty in
        let r = put_request t k Bigstring.empty in
        if not (success r.status) then fail ~op:"put" r;
        match
          put_request t
            ~headers:[("if-match", impossible_etag)]
            k Bigstring.empty
        with
          | { status = 412; _ } -> Atomic.set t.replaces Honoured
          | r when success r.status || refuses_header "If-Match" r ->
              Atomic.set t.replaces Ignored;
              ignored ()
          | r -> fail ~op:"put_if_unchanged" r)

(* §4: [None] is a create that never reads the holder; an ETag is the
   version the caller read. *)
let put_if_unchanged t k body expected =
  (match expected with None -> check_claims t | Some _ -> ());
  check_replaces t;
  let header =
    match expected with
      | None -> ("if-none-match", "*")
      | Some etag -> ("if-match", "\"" ^ etag ^ "\"")
  in
  match put_request t ~headers:[header] k body with
    | r when success r.status -> Tsync_store.Store.Written
    | { status = 412; _ } -> Changed
    | { status = 404; _ } when expected <> None -> Changed
    | r when refuses_header "If-Match" r || cannot_claim r ->
        Fail.raise_ Fail.Refused "s3: this store cannot replace conditionally"
    | r -> fail ~op:"put_if_unchanged" r

(* §1: AWS by region, else the endpoint as given, https for a bare host. *)
let endpoint_url ~region = function
  | None ->
      Printf.sprintf "https://s3.%s.amazonaws.com%s" region
        (if String.starts_with ~prefix:"cn-" region then ".cn" else "")
  | Some e ->
      let e =
        if
          String.starts_with ~prefix:"http://" e
          || String.starts_with ~prefix:"https://" e
        then e
        else "https://" ^ e
      in
      if String.ends_with ~suffix:"/" e then String.sub e 0 (String.length e - 1)
      else e

let create ~domain ~admission ~name fields =
  let str k =
    match List.assoc_opt k fields with
      | Some (Field_spec.S s) when String.trim s <> "" -> Some (String.trim s)
      | _ -> None
  in
  let required k =
    match str k with
      | Some v -> v
      | None -> Fail.invalid "backend %s: no %s" name k
  in
  let region = Option.value ~default:"us-east-1" (str "region") in
  if not (valid_region region) then
    Fail.invalid "backend %s: bad region %S" name region;
  let api = Client.endpoint (endpoint_url ~region (str "endpoint")) in
  if Client.base_path api <> "" then
    Fail.invalid "backend %s: an S3 endpoint takes no path" name;
  let t =
    {
      api;
      bucket = required "bucket";
      credentials =
        {
          access_key = required "accessKeyId";
          secret = required "secretAccessKey";
          region;
        };
      unsigned_payload =
        (match List.assoc_opt "unsignedPayload" fields with
          | Some (Field_spec.B b) -> b
          | _ -> false);
      etag_is_md5 =
        (match List.assoc_opt "etagIsMd5" fields with
          | Some (Field_spec.B b) -> b
          | _ -> true);
      domain;
      claims =
        Atomic.make (if str "endpoint" = None then Honoured else Unchecked);
      replaces =
        Atomic.make (if str "endpoint" = None then Honoured else Unchecked);
    }
  in
  Object_store.make ~name ~admission ?share_url:(str "shareUrl")
    {
      put =
        (fun k body ->
          let r = put_request t k body in
          if not (success r.status) then fail ~op:"put" r);
      put_if_absent =
        (fun k body ->
          check_claims t;
          put_if_absent t k body);
      put_if_unchanged = put_if_unchanged t;
      get_opt = get_opt t;
      get_range = get_range t;
      head_opt = head_opt t;
      delete = delete t;
      delete_page = delete_page t;
      copy = copy t;
      list_page = list_page t;
    }

let () = Tsync_store.Driver.register "s3" { fields; linkless = false; create }
