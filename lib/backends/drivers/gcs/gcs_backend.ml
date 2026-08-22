(* Google Cloud Storage over the JSON API: every request carries a bearer token
   minted from a service-account key ({!Gcs_auth}), and unlike s3 there is no
   per-request signing. *)

open Lwt.Syntax
module Auth = Gcs_auth

exception Cancelled = Backend.Cancelled

type t = {
  client : Http_client.t;
  bucket : string;
  base : string; (* scheme + host, no trailing slash *)
  auth : Auth.t option;
      (* [None] is anonymous, for emulators on a custom endpoint. *)
  share_url : string option;
}

let code = Http_client.code
let is_ok = Http_client.is_ok
let backend_error = Http_client.backend_error

(* An object name is a single path segment, so [/] and other reserved characters
   must be percent-encoded; the escaped form survives
   [Uri.of_string]/[path_and_query] to the wire. *)
let enc_key key = Uri.pct_encode ~component:`Generic key
let obj_path t key = t.base ^ "/storage/v1/b/" ^ t.bucket ^ "/o/" ^ enc_key key

let upload_uri t key =
  Uri.of_string
    (t.base ^ "/upload/storage/v1/b/" ^ t.bucket ^ "/o?uploadType=media&name="
   ^ enc_key key)

(* A response that never arrives — a connection dropped without an EOF reaching
   us — otherwise parks its caller for the life of the process. The deferred
   queue runs one worker, so that is every job behind it waiting, with nothing
   logged and no traffic to see.

   Measured against the connections that go this way: every one of them is
   answered on the first retry, so waiting longer buys a caller nothing — the
   connection is already gone by the second the request is made. Sixty seconds
   against a link that answers in 150ms and would take about eight for a chunk
   at its worst observed rate. *)
let request_timeout = 60.

(* Minting a token reaches the network, which is why the pool takes these as a
   thunk: it belongs inside the request's deadline rather than before it. *)
let headers t ~ctype ~extra_headers () =
  let+ auth_header =
    match t.auth with
      | None -> Lwt.return []
      | Some a ->
          let+ tok = Auth.token a in
          [("Authorization", "Bearer " ^ tok)]
  in
  Cohttp.Header.of_list
    (extra_headers
    @
      match ctype with
      | Some c -> ("Content-Type", c) :: auth_header
      | None -> auth_header)

let call_retry t ~meth ?ctype ?(extra_headers = []) ?body op uri =
  Http_client.call_retry t.client
    ~headers:(headers t ~ctype ~extra_headers)
    ~meth ?body op uri

(* Only an object's own bytes are worth keeping off the heap; the JSON and XML
   verbs below carry a body small enough to read as a string, and one they have
   to parse anyway. *)
let call_text t ~meth ?ctype ?(extra_headers = []) ?body op uri =
  let body = Option.map Bigstring.of_string body in
  Http_client.call_text t.client
    ~headers:(headers t ~ctype ~extra_headers)
    ~meth ?body op uri

let str_member key j =
  match Yojson.Safe.Util.member key j with `String s -> s | _ -> ""

(* Howard Hinnant's civil-date algorithm, so turning GCS's RFC-3339 [updated]
   timestamp into epoch seconds needs no date library. *)
let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = (((153 * if m > 2 then m - 3 else m + 9) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

(* GCS timestamps are always UTC ("...Z"); ignore the fractional seconds. *)
let parse_rfc3339 s =
  try
    Scanf.sscanf s "%d-%d-%dT%d:%d:%d" (fun y mo d h mi se ->
        float_of_int
          ((days_from_civil y mo d * 86400) + (h * 3600) + (mi * 60) + se))
  with _ -> 0.

let size_of j =
  match Yojson.Safe.Util.member "size" j with
    | `String s -> ( try int_of_string s with _ -> 0)
    | `Int n -> n
    | _ -> 0

let entry_of_json name j =
  {
    Backend.key = name;
    size = size_of j;
    last_modified = parse_rfc3339 (str_member "updated" j);
    etag = (match str_member "etag" j with "" -> None | e -> Some e);
  }

let put t ~key ~data () =
  let+ resp, body =
    call_retry t ~meth:`POST ~ctype:"application/octet-stream" ~body:data "put"
      (upload_uri t key)
  in
  if not (is_ok resp) then
    raise (backend_error "put" (code resp) (Bigstring.to_string body))

let get t ~key () =
  let uri = Uri.of_string (obj_path t key ^ "?alt=media") in
  let+ resp, body = call_retry t ~meth:`GET "get" uri in
  if is_ok resp then body
  else raise (backend_error "get" (code resp) (Bigstring.to_string body))

let get_opt t ~key () =
  let uri = Uri.of_string (obj_path t key ^ "?alt=media") in
  let+ resp, body = call_retry t ~meth:`GET "get_opt" uri in
  if is_ok resp then Some body
  else if code resp = 404 then None
  else raise (backend_error "get_opt" (code resp) (Bigstring.to_string body))

(* [ifGenerationMatch=0] means "only if this object does not exist", and the 412
   GCS answers when it already does is the claim being lost, not an error. *)
let put_if_absent t ~key ~data () =
  let uri =
    Uri.add_query_param' (upload_uri t key) ("ifGenerationMatch", "0")
  in
  let* resp, body =
    call_retry t ~meth:`POST ~ctype:"application/octet-stream" ~body:data
      "put_if_absent" uri
  in
  if is_ok resp then Lwt.return data
  else if code resp = 412 then get t ~key ()
  else raise (backend_error "put_if_absent" (code resp) (Bigstring.to_string body))

let head_opt t ~key () =
  let uri = Uri.of_string (obj_path t key) in
  let+ resp, body = call_text t ~meth:`GET "head" uri in
  if is_ok resp then Some (entry_of_json key (Yojson.Safe.from_string body))
  else if code resp = 404 then None
  else raise (backend_error "head" (code resp) body)

let delete t ~key () =
  let uri = Uri.of_string (obj_path t key) in
  let+ resp, body = call_text t ~meth:`DELETE "delete" uri in
  if is_ok resp || code resp = 404 then ()
  else raise (backend_error "delete" (code resp) body)

(* Bulk delete is the one verb that leaves the JSON API, which has no equivalent:
   the XML API takes 1000 objects in a request, against 1000 requests to do the
   same one at a time. Same bearer token, so nothing else changes.

   Enough XML for one request and one answer, rather than a parser dependency for
   a single call. Both halves are pure and tested; what is not tested here is the
   roundtrip, this driver having no emulator in the suite. *)
let bulk_delete_limit = 1000

let xml_escape s =
  let b = Buffer.create (String.length s + 16) in
  String.iter
    (function
      | '&' -> Buffer.add_string b "&amp;"
      | '<' -> Buffer.add_string b "&lt;"
      | '>' -> Buffer.add_string b "&gt;"
      | '"' -> Buffer.add_string b "&quot;"
      | '\'' -> Buffer.add_string b "&apos;"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

(* [Quiet] so a clean delete of a thousand objects answers with an empty
   [DeleteResult] instead of a thousand [Deleted] elements. *)
let delete_body keys =
  let b = Buffer.create (64 * List.length keys) in
  Buffer.add_string b "<Delete><Quiet>true</Quiet>";
  List.iter
    (fun key ->
      Buffer.add_string b "<Object><Key>";
      Buffer.add_string b (xml_escape key);
      Buffer.add_string b "</Key></Object>")
    keys;
  Buffer.add_string b "</Delete>";
  Buffer.contents b

let find_from s sub from =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then None
    else if String.sub s i m = sub then Some i
    else go (i + 1)
  in
  go (max 0 from)

(* Every [<Error>] the answer reports, as (code, key). Empty on a clean delete,
   [Quiet] having kept the successes out of it. *)
let delete_errors body =
  let text tag from =
    match find_from body ("<" ^ tag ^ ">") from with
      | None -> ""
      | Some i -> (
          let start = i + String.length tag + 2 in
          match find_from body ("</" ^ tag ^ ">") start with
            | None -> ""
            | Some j -> String.sub body start (j - start))
  in
  let rec go acc from =
    match find_from body "<Error>" from with
      | None -> List.rev acc
      | Some i -> go ((text "Code" i, text "Key" i) :: acc) (i + 7)
  in
  go [] 0

(* Path-style bucket, the XML API's own shape, so a custom endpoint keeps
   working. *)
let delete_uri t = Uri.of_string (t.base ^ "/" ^ t.bucket ^ "?delete")

let delete_multi t keys =
  let rec go = function
    | [] -> Lwt.return_unit
    | batch ->
        let here = List.filteri (fun i _ -> i < bulk_delete_limit) batch in
        let rest = List.filteri (fun i _ -> i >= bulk_delete_limit) batch in
        let request = delete_body here in
        (* Required, and answered with a 400 naming it when absent: this is the
           one request whose body the store checks before acting on it, a
           truncated list of keys to delete being worse than no list at all.
           [Stdlib.Digest] is MD5, which is all this is. *)
        let* resp, body =
          call_text t ~meth:`POST ~ctype:"application/xml"
            ~extra_headers:
              [("Content-MD5", Base64.encode_string (Digest.string request))]
            ~body:request "delete_multi" (delete_uri t)
        in
        if not (is_ok resp) then
          raise (backend_error "delete_multi" (code resp) body);
        (* A 2xx says the request was understood, not that every object went:
           what failed comes back per key in the body, and reading it is the
           difference between a delete that worked and one that was merely
           accepted.

           Classified [Transient] rather than from the status, which is 200 and
           would read as a permanent refusal: the codes here are per key, a
           retried batch costs a repeat of something idempotent, and being wrong
           the other way strands the objects on a copy nothing walks. *)
          (match
             List.filter
               (fun (c, _) -> not (Backend.absent_code c))
               (delete_errors body)
           with
          | [] -> ()
          | (code_, key) :: _ as failed ->
              raise
                (Backend.failed ~kind:Backend.Transient ~op:"delete_multi"
                   (Printf.sprintf
                      "%d of %d object(s) not deleted; first was %s: %s"
                      (List.length failed) (List.length here) key code_)));
        go rest
  in
  go keys

let copy t ~src_key ~dst_key () =
  let* data = get t ~key:src_key () in
  put t ~key:dst_key ~data ()

let list_uri t ?max_keys ~prefix ~page_token () =
  let q =
    [("prefix", prefix)]
    @ (match page_token with Some tk -> [("pageToken", tk)] | None -> [])
    @
      match max_keys with
      | Some n -> [("maxResults", string_of_int n)]
      | None -> []
  in
  Uri.add_query_params'
    (Uri.of_string (t.base ^ "/storage/v1/b/" ^ t.bucket ^ "/o"))
    q

let parse_list body =
  let j = Yojson.Safe.from_string body in
  let items =
    match Yojson.Safe.Util.member "items" j with
      | `List l ->
          List.map (fun it -> entry_of_json (str_member "name" it) it) l
      | _ -> []
  in
  let next =
    match Yojson.Safe.Util.member "nextPageToken" j with
      | `String tk -> Some tk
      | _ -> None
  in
  (items, next)

(* Reverse accumulation for O(1) prepend, as the s3 backend does. [max_keys] caps
   the total and stops paging once reached. *)
let list_all t ?max_keys ~prefix () =
  let enough acc =
    match max_keys with
      | None -> false
      | Some n -> List.length (List.concat acc) >= n
  in
  let rec collect acc page_token =
    if enough acc then Lwt.return (List.concat (List.rev acc))
    else (
      let uri = list_uri t ?max_keys ~prefix ~page_token () in
      let* resp, body = call_text t ~meth:`GET "ls" uri in
      if not (is_ok resp) then Lwt.fail (backend_error "ls" (code resp) body)
      else begin
        let items, next = parse_list body in
        let acc = items :: acc in
        match next with
          | Some _ -> collect acc next
          | None -> Lwt.return (List.concat (List.rev acc))
      end)
  in
  collect [] None

let make ?endpoint ?service_account_key ?share_url ~bucket () :
    (module Backend.S) =
  let base =
    match endpoint with
      | Some e when e <> "" -> e
      | _ -> "https://storage.googleapis.com"
  in
  let base =
    let n = String.length base in
    if n > 0 && base.[n - 1] = '/' then String.sub base 0 (n - 1) else base
  in
  let auth = Option.map Auth.of_service_account_json service_account_key in
  let t =
    {
      client = Http_client.create ~name:"gcs" ~timeout:request_timeout ();
      bucket;
      base;
      auth;
      share_url;
    }
  in
  (* The verifier's job bodies are JSON, and it is handed this rather than the
     module's [put] below, which speaks in chunks. *)
  let put_text ~key ~data () = put t ~key ~data:(Bigstring.of_string data) () in
  (module struct
    let put ~key ~data () = put t ~key ~data ()
    let put_if_absent ~key ~data () = put_if_absent t ~key ~data ()
    let get ~key () = get t ~key ()
    let get_opt ~key () = get_opt t ~key ()
    let head_opt ~key () = head_opt t ~key ()
    let delete ~key () = delete t ~key ()
    let delete_multi keys = delete_multi t keys
    let copy ~src_key ~dst_key () = copy t ~src_key ~dst_key ()
    let list_prefix ?max_keys ~prefix () = list_all t ?max_keys ~prefix ()

    (* The batch API carries metadata, not bodies: {!Backend.Batched} fans
       these out. *)
    let get_many = None

    let verify_all ~chunk_prefix () =
      let+ n =
        Verifier.queue
          ~on_progress:(fun ~done_ ~total ->
            if done_ mod 256 = 0 || done_ = total then
              Log.info "verify: queued %d/%d shard request(s)" done_ total)
          ~put:put_text ~chunk_prefix ()
      in
      `Queued n

    (* Taken as given, as [verified] is and for the same reason: the function
       that consumes these is deployed by the terraform that makes the bucket,
       and a deployment half applied is not a state this reports its way out of.
       A request nothing picks up is reported by [tsync gc --status] and
       re-delivered by [tsync gc --retry-jobs]. *)
    let discard ~chunk_prefix ~run ~name ~keys () =
      let+ () =
        Discard_job.queue ~put:put_text ~chunk_prefix ~run ~name ~keys ()
      in
      `Queued

    (* No chunk size or concurrency opinion: an object store is limited by the
       network and its own concurrency, neither measurable from here.

       [verified] is taken as given rather than probed or configured: the
       function that checks these chunks is deployed by the same terraform that
       makes the bucket, and a deployment half applied is not a state this
       reports its way out of. *)
    let capabilities ~prefix:_ () =
      Lwt.return
        { Backend.no_caps with share_url = t.share_url; verified = true }
  end)

let spec =
  Field_spec.
    [
      {
        name = "bucket";
        label = "GCS bucket";
        typ = `String;
        default = None;
        secret = false;
      };
      {
        name = "serviceAccountKey";
        label =
          "Service account JSON key (blank only for an anonymous emulator)";
        typ = `String;
        default = Some "";
        secret = true;
      };
      {
        name = "endpoint";
        label = "Custom endpoint (blank for Google)";
        typ = `String;
        default = Some "";
        secret = false;
      };
      {
        name = "shareUrl";
        label = "Share function URL (blank if this bucket has no share service)";
        typ = `String;
        default = Some "";
        secret = false;
      };
    ]

let () =
  let req get key =
    match get key with
      | Some v -> v
      | None -> failwith ("gcs backend: missing field: " ^ key)
  in
  let opt get key = match get key with Some "" | None -> None | s -> s in
  Backend.register ~spec "gcs" (fun get ->
      make ?endpoint:(opt get "endpoint")
        ?service_account_key:(opt get "serviceAccountKey")
        ?share_url:(opt get "shareUrl") ~bucket:(req get "bucket") ())
