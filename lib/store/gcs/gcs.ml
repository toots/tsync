open Tsync_core

let fields =
  Field_spec.
    [
      f ~required:true
        ~check:(fun b ->
          if b = "" || String.contains b '/' then Some "invalid bucket name"
          else None)
        "bucket" "Bucket" String;
      f ~secret:true "serviceAccountKey" "Service account key (JSON)" String;
      f ~check:(http_url ~bare_host:false) "endpoint" "Endpoint" String;
      f "shareUrl" "Share URL" String;
    ]

(* §3: every byte outside the unreserved set is escaped, [/] included, so the
   key reaches the wire as one path segment. *)
let segment s =
  String.concat ""
    (List.map
       (function
         | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~') as c
           ->
             String.make 1 c
         | c -> Printf.sprintf "%%%02X" (Char.code c))
       (List.of_seq (String.to_seq s)))

let rfc3339 s =
  match Ptime.of_rfc3339 s with
    | Ok (t, _, _) -> Ptime.to_float_s t
    | Error _ -> Fail.corrupt "gcs: bad time %S" s

let entry_of_json j =
  let open Yojson.Safe.Util in
  let str k = match member k j with `String s -> Some s | _ -> None in
  let name =
    match str "name" with
      | Some n -> n
      | None -> Fail.corrupt "gcs: an object without a name"
  in
  let size =
    match member "size" j with
      | `String s -> (
          match int_of_string_opt s with
            | Some n -> n
            | None -> Fail.corrupt "gcs: bad size %S" s)
      | `Int n -> n
      | _ -> Fail.corrupt "gcs: bad size for %s" name
  in
  let last_modified =
    match str "updated" with
      | Some u -> rfc3339 u
      | None -> Fail.corrupt "gcs: no time for %s" name
  in
  { Tsync_store.Object_store.name; size; last_modified; etag = str "etag" }

type t = {
  api : Tsync_http.Client.endpoint;
  bucket : string;
  auth : Gcs_auth.t option;
}

let success s = s >= 200 && s < 300

(* §2: a 401 means the token was rejected; one fresh token, one more try. *)
let call t ?(headers = []) ?body ~meth target =
  let send tok =
    Tsync_http.Client.request t.api ~meth ?body target ~headers:(fun () ->
        headers
        @
          match tok with
          | Some tok -> [("authorization", "Bearer " ^ tok)]
          | None -> [])
  in
  match t.auth with
    | None -> send None
    | Some a -> (
        let tok = Gcs_auth.token a in
        match send (Some tok) with
          | { status = 401; _ } ->
              Gcs_auth.invalidate a tok;
              send (Some (Gcs_auth.token a))
          | r -> r)

let fail ~op (r : Tsync_http.Client.response) =
  let retry_after =
    Option.bind
      (Tsync_http.Codec.header r.headers "retry-after")
      float_of_string_opt
  in
  raise
    (Fail.E
       (Tsync_store.Object_store.status_failure ~op ?retry_after
          ~body:(Tsync_http.Client.excerpt r.body)
          r.status))

let json ~op (r : Tsync_http.Client.response) =
  try Yojson.Safe.from_string (Bigstring.to_string r.body)
  with _ -> Fail.corrupt "gcs %s: an answer that is not JSON" op

let obj t k =
  Printf.sprintf "/storage/v1/b/%s/o/%s" (segment t.bucket)
    (segment (Key.to_string k))

let get_opt t k =
  match call t ~meth:"GET" (obj t k ^ "?alt=media") with
    | r when success r.status -> Some r.body
    | { status = 404; _ } -> None
    | r -> fail ~op:"get" r

let upload t ?(extra = "") k body =
  call t ~meth:"POST" ~body
    ~headers:[("content-type", "application/octet-stream")]
    (Printf.sprintf "/upload/storage/v1/b/%s/o?uploadType=media&name=%s%s"
       (segment t.bucket)
       (segment (Key.to_string k))
       extra)

let claim_retries = 3

let put_if_absent t k body =
  let rec go n =
    match upload t ~extra:"&ifGenerationMatch=0" k body with
      | r when success r.status -> Tsync_store.Store.Won
      | { status = 412; _ } -> (
          match get_opt t k with
            | Some held when Bigstring.equal held body -> Won
            | Some held -> Held held
            | None when n > 1 -> go (n - 1)
            | None ->
                Fail.raise_ Fail.Load "gcs: %s changed hands during a claim"
                  (Key.to_string k))
      | r -> fail ~op:"put_if_absent" r
  in
  go claim_retries

(* A 206 must say it starts where asked; a 200 is the whole object, which is
   only an answer when it fits the range. *)
let get_range t k off len =
  let r =
    call t ~meth:"GET"
      (obj t k ^ "?alt=media")
      ~headers:[("range", Printf.sprintf "bytes=%d-%d" off (off + len - 1))]
  in
  match r.status with
    | 206 -> (
        match Tsync_http.Codec.header r.headers "content-range" with
          | Some cr
            when String.starts_with ~prefix:(Printf.sprintf "bytes %d-" off) cr
            ->
              Some r.body
          | _ ->
              Fail.corrupt "gcs: %s: a range answer that starts elsewhere"
                (Key.to_string k))
    | 200 when off = 0 -> Some r.body
    | 200 ->
        Some
          (let n = Bigstring.length r.body in
           if off >= n then Bigstring.empty
           else Bigstring.sub r.body ~off ~len:(min len (n - off)))
    | 416 -> Some Bigstring.empty
    | 404 -> None
    | _ -> fail ~op:"get_range" r

let head_opt t k =
  match call t ~meth:"GET" (obj t k) with
    | r when success r.status ->
        let e = entry_of_json (json ~op:"head" r) in
        Some
          {
            Tsync_store.Store.key = k;
            size = e.size;
            last_modified = e.last_modified;
            etag = e.etag;
          }
    | { status = 404; _ } -> None
    | r -> fail ~op:"head" r

let delete t k =
  match call t ~meth:"DELETE" (obj t k) with
    | r when success r.status -> true
    | { status = 404; _ } -> false
    | r -> fail ~op:"delete" r

(* §3.3: the XML API takes up to 1000 keys with a mandatory Content-MD5; a key
   XML cannot carry goes alone. *)
let delete_page t keys =
  let unsafe, safe =
    List.partition
      (fun k -> not (Tsync_store.Bucket_xml.safe (Key.to_string k)))
      keys
  in
  List.iter (fun k -> ignore (delete t k)) unsafe;
  if safe <> [] then (
    let body =
      Tsync_store.Bucket_xml.delete_body (List.map Key.to_string safe)
    in
    let r =
      call t ~meth:"POST" ~body:(Bigstring.of_string body)
        ~headers:
          [
            ("content-type", "application/xml");
            ("content-md5", Base64.encode_string (Digest.string body));
          ]
        (Printf.sprintf "/%s?delete" (segment t.bucket))
    in
    if not (success r.status) then fail ~op:"delete_multi" r;
    match
      List.filter
        (fun (code, _) -> code <> "NoSuchKey" && code <> "NotFound")
        (Tsync_store.Bucket_xml.delete_errors (Bigstring.to_string r.body))
    with
      | [] -> ()
      | (code, key) :: _ as refused ->
          let f =
            Tsync_store.Object_store.per_key_failure ~op:"delete_multi" ~code
              ~key
          in
          raise
            (Fail.E
               {
                 f with
                 reason =
                   Printf.sprintf "%s (%d keys refused)" f.reason
                     (List.length refused);
               }))

let copy t src dst =
  let rec go token =
    let target =
      Printf.sprintf "/storage/v1/b/%s/o/%s/rewriteTo/b/%s/o/%s%s"
        (segment t.bucket)
        (segment (Key.to_string src))
        (segment t.bucket)
        (segment (Key.to_string dst))
        (match token with
          | Some tok -> "?rewriteToken=" ^ segment tok
          | None -> "")
    in
    match call t ~meth:"POST" ~body:Bigstring.empty target with
      | r when success r.status -> (
          match Yojson.Safe.Util.member "rewriteToken" (json ~op:"copy" r) with
            | `String tok -> go (Some tok)
            | _ -> ())
      | { status = 404; _ } ->
          Fail.absent "gcs: %s: no such object" (Key.to_string src)
      | r -> fail ~op:"copy" r
  in
  go None

let list_page t ~prefix ~token ~max =
  let target =
    Printf.sprintf "/storage/v1/b/%s/o?prefix=%s&fields=%s%s%s"
      (segment t.bucket)
      (segment (Key.prefix_to_string prefix))
      (segment "items(name,size,updated,etag),nextPageToken")
      (match token with Some tok -> "&pageToken=" ^ segment tok | None -> "")
      (match max with
        | Some m -> Printf.sprintf "&maxResults=%d" (min m 1000)
        | None -> "")
  in
  match call t ~meth:"GET" target with
    | r when success r.status -> (
        let j = json ~op:"list" r in
        let items =
          match Yojson.Safe.Util.member "items" j with
            | `List l -> List.map entry_of_json l
            | `Null -> []
            | _ -> Fail.corrupt "gcs: a listing whose items are not a list"
        in
        ( items,
          match Yojson.Safe.Util.member "nextPageToken" j with
            | `String tok -> Some tok
            | _ -> None ))
    | r -> fail ~op:"list" r

let create ~domain:_ ~admission ~name fields =
  let str k =
    match List.assoc_opt k fields with
      | Some (Field_spec.S s) when String.trim s <> "" -> Some (String.trim s)
      | _ -> None
  in
  let bucket =
    match str "bucket" with
      | Some b -> b
      | None -> Fail.invalid "backend %s: no bucket" name
  in
  let endpoint =
    let e =
      Option.value ~default:"https://storage.googleapis.com" (str "endpoint")
    in
    if String.ends_with ~suffix:"/" e then String.sub e 0 (String.length e - 1)
    else e
  in
  let auth = Option.map Gcs_auth.create (str "serviceAccountKey") in
  let api = Tsync_http.Client.endpoint endpoint in
  if auth = None && not (Field_spec.is_loopback (Tsync_http.Client.host api))
  then
    Fail.invalid
      "backend %s: a service account key is required outside an emulator" name;
  let t = { api; bucket; auth } in
  Tsync_store.Object_store.make ~name ~admission ?share_url:(str "shareUrl")
    {
      put =
        (fun k body ->
          let r = upload t k body in
          if not (success r.status) then fail ~op:"put" r);
      put_if_absent = put_if_absent t;
      get_opt = get_opt t;
      get_range = get_range t;
      head_opt = head_opt t;
      delete = delete t;
      delete_page = delete_page t;
      copy = copy t;
      list_page = list_page t;
    }

let () = Tsync_store.Driver.register "gcs" { fields; linkless = false; create }
