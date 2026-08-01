(* Google Cloud Storage over the JSON API. Every request carries a bearer token
   minted from a service-account key (see [Gcs_auth]); unlike s3 there is no
   per-request signing, so the verbs are thin HTTP calls. *)

open Lwt.Syntax
module Auth = Gcs_auth

exception Cancelled = Backend.Cancelled

type t = {
  bucket : string;
  base : string; (* scheme + host, no trailing slash *)
  auth : Auth.t option;
      (* [None] is anonymous, for emulators on a custom endpoint. *)
  share_url : string option;
}

let gcs_eio msg = Unix.Unix_error (Unix.EIO, "gcs", msg)

let backend_error op code body =
  gcs_eio (Printf.sprintf "%s: HTTP %d: %s" op code body)

let code resp = Cohttp.Code.code_of_status (Cohttp.Response.status resp)
let is_ok resp = code resp >= 200 && code resp < 300

(* An object name is a single path segment, so [/] and other reserved characters
   must be percent-encoded. [`Generic] encodes everything not unreserved, and the
   escaped form survives [Uri.of_string]/[path_and_query] to the wire. *)
let enc_key key = Uri.pct_encode ~component:`Generic key
let obj_path t key = t.base ^ "/storage/v1/b/" ^ t.bucket ^ "/o/" ^ enc_key key

let upload_uri t key =
  Uri.of_string
    (t.base ^ "/upload/storage/v1/b/" ^ t.bucket ^ "/o?uploadType=media&name="
   ^ enc_key key)

let max_attempts = 8

let call t ~meth ?ctype ?(body = "") uri =
  let* auth_header =
    match t.auth with
      | None -> Lwt.return []
      | Some a ->
          let+ tok = Auth.token a in
          [("Authorization", "Bearer " ^ tok)]
  in
  let headers =
    Cohttp.Header.of_list
      (match ctype with
        | Some c -> ("Content-Type", c) :: auth_header
        | None -> auth_header)
  in
  let* resp, rbody =
    Cohttp_lwt_unix.Client.call ~headers
      ~body:(Cohttp_lwt.Body.of_string body)
      meth uri
  in
  let+ s = Cohttp_lwt.Body.to_string rbody in
  (resp, s)

(* 5xx and 429 are transient: back off and retry. [Cancelled] never retries. *)
let is_transient_code c = c >= 500 || c = 429

let call_retry t ~meth ?ctype ?body op uri =
  let rec go attempt =
    let* outcome =
      Lwt.catch
        (fun () ->
          let+ r = call t ~meth ?ctype ?body uri in
          `Ret r)
        (fun exn -> Lwt.return (`Raised exn))
    in
    let retry reason =
      let backoff = Float.min 20. (0.5 *. (2. ** float_of_int (attempt - 1))) in
      let delay = backoff *. (0.5 +. Random.float 1.0) in
      Log.warn "gcs %s: %s; retrying (%d/%d) in %.1fs" op reason attempt
        max_attempts delay;
      let* () = Lwt_unix.sleep delay in
      go (attempt + 1)
    in
    match outcome with
      | `Ret (resp, body)
        when is_transient_code (code resp) && attempt < max_attempts ->
          retry (Printf.sprintf "HTTP %d: %s" (code resp) body)
      | `Ret r -> Lwt.return r
      | `Raised Cancelled -> Lwt.fail Cancelled
      | `Raised exn when attempt < max_attempts ->
          retry (Printexc.to_string exn)
      | `Raised exn -> Lwt.fail exn
  in
  go 1

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
  }

let put t ~key ~data () =
  let+ resp, body =
    call_retry t ~meth:`POST ~ctype:"application/octet-stream" ~body:data "put"
      (upload_uri t key)
  in
  if not (is_ok resp) then raise (backend_error "put" (code resp) body)

let get t ~key () =
  let uri = Uri.of_string (obj_path t key ^ "?alt=media") in
  let+ resp, body = call_retry t ~meth:`GET "get" uri in
  if is_ok resp then body else raise (backend_error "get" (code resp) body)

let get_opt t ~key () =
  let uri = Uri.of_string (obj_path t key ^ "?alt=media") in
  let+ resp, body = call_retry t ~meth:`GET "get_opt" uri in
  if is_ok resp then Some body
  else if code resp = 404 then None
  else raise (backend_error "get_opt" (code resp) body)

let head_opt t ~key () =
  let uri = Uri.of_string (obj_path t key) in
  let+ resp, body = call_retry t ~meth:`GET "head" uri in
  if is_ok resp then Some (entry_of_json key (Yojson.Safe.from_string body))
  else if code resp = 404 then None
  else raise (backend_error "head" (code resp) body)

let delete t ~key () =
  let uri = Uri.of_string (obj_path t key) in
  let+ resp, body = call_retry t ~meth:`DELETE "delete" uri in
  if is_ok resp || code resp = 404 then ()
  else raise (backend_error "delete" (code resp) body)

(* No S3-style batch delete: fan out single deletes, bounded per batch. *)
let delete_multi t keys =
  let rec go = function
    | [] -> Lwt.return_unit
    | batch ->
        let here = List.filteri (fun i _ -> i < 32) batch in
        let rest = List.filteri (fun i _ -> i >= 32) batch in
        let* () = Lwt_list.iter_p (fun key -> delete t ~key ()) here in
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
      let* resp, body = call_retry t ~meth:`GET "ls" uri in
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
  let t = { bucket; base; auth; share_url } in
  (module struct
    let put ~key ~data () = put t ~key ~data ()
    let get ~key () = get t ~key ()
    let get_opt ~key () = get_opt t ~key ()
    let head_opt ~key () = head_opt t ~key ()
    let delete ~key () = delete t ~key ()
    let delete_multi keys = delete_multi t keys
    let copy ~src_key ~dst_key () = copy t ~src_key ~dst_key ()
    let list_prefix ?max_keys ~prefix () = list_all t ?max_keys ~prefix ()
    let share_url ~prefix:_ () = Lwt.return t.share_url
    let default_chunk_size ~prefix:_ () = Lwt.return_none

    (* No opinion: an object store is limited by the network and its own
       concurrency, neither measurable from here. *)
    let max_concurrency ~prefix:_ () = Lwt.return_none
  end)

let spec =
  Backend.
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
