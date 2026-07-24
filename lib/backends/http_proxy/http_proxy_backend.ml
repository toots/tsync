open Lwt.Syntax

exception Cancelled = Backend.Cancelled

type t = {
  base_uri : Uri.t;
  secret : string;
  mutable share_url_cache : string option Lwt.t option;
}

let max_attempts = 8

let backend_error op code body =
  Backend.Backend_error
    (Printf.sprintf "http-proxy %s: HTTP %d: %s" op code body)

(* Sign method + request-target + body with the shared secret, then issue the
   request over cohttp (TLS handled by conduit per the global [Tls_conf]). Returns
   the response and its body as a string. *)
let call t ~meth ?(body = "") uri =
  let resource = Uri.path_and_query uri in
  let headers =
    Cohttp.Header.of_list
      (Http_proxy.Auth.request_headers ~secret:t.secret
         ~meth:(Cohttp.Code.string_of_method meth)
         ~path:resource ~body)
  in
  let* resp, rbody =
    Cohttp_lwt_unix.Client.call ~headers
      ~body:(Cohttp_lwt.Body.of_string body)
      meth uri
  in
  let+ s = Cohttp_lwt.Body.to_string rbody in
  (resp, s)

(* Connection failures and 5xx are transient (back off + retry); [Cancelled] never
   retries. All proxied operations are idempotent, so retrying is safe. *)
let code resp = Cohttp.Code.code_of_status (Cohttp.Response.status resp)
let is_ok resp = code resp >= 200 && code resp < 300

let call_retry t ~meth ?body op uri =
  let rec go attempt =
    let* outcome =
      Lwt.catch
        (fun () ->
          let+ r = call t ~meth ?body uri in
          `Ret r)
        (fun exn -> Lwt.return (`Raised exn))
    in
    let retry reason =
      let backoff = Float.min 20. (0.5 *. (2. ** float_of_int (attempt - 1))) in
      let delay = backoff *. (0.5 +. Random.float 1.0) in
      Log.warn "http-proxy %s: %s; retrying (%d/%d) in %.1fs" op reason attempt
        max_attempts delay;
      let* () = Lwt_unix.sleep delay in
      go (attempt + 1)
    in
    match outcome with
      | `Ret (resp, body) when code resp >= 500 && attempt < max_attempts ->
          retry (Printf.sprintf "HTTP %d: %s" (code resp) body)
      | `Ret r -> Lwt.return r
      | `Raised Cancelled -> Lwt.fail Cancelled
      | `Raised exn when attempt < max_attempts ->
          retry (Printexc.to_string exn)
      | `Raised exn -> Lwt.fail exn
  in
  go 1

let obj_uri t key =
  Uri.with_path t.base_uri ("/o/" ^ Http_proxy.Wire.encode_key key)

let put t ~key ~data () =
  let+ resp, body = call_retry t ~meth:`PUT ~body:data "put" (obj_uri t key) in
  if not (is_ok resp) then raise (backend_error "put" (code resp) body)

let get t ~key () =
  let+ resp, body = call_retry t ~meth:`GET "get" (obj_uri t key) in
  if is_ok resp then body else raise (backend_error "get" (code resp) body)

let get_opt t ~key () =
  let+ resp, body = call_retry t ~meth:`GET "get_opt" (obj_uri t key) in
  if is_ok resp then Some body
  else if code resp = 404 then None
  else raise (backend_error "get_opt" (code resp) body)

let head_opt t ~key () =
  let+ resp, body = call_retry t ~meth:`HEAD "head" (obj_uri t key) in
  if is_ok resp then (
    let h = Cohttp.Response.headers resp in
    let size =
      match Cohttp.Header.get h "x-tsync-size" with
        | Some s -> int_of_string s
        | None -> 0
    in
    let last_modified =
      match Cohttp.Header.get h "x-tsync-last-modified" with
        | Some s -> float_of_string s
        | None -> 0.
    in
    Some { Backend.key; size; last_modified })
  else if code resp = 404 then None
  else raise (backend_error "head" (code resp) body)

let delete t ~key () =
  let+ resp, body = call_retry t ~meth:`DELETE "delete" (obj_uri t key) in
  if not (is_ok resp) then raise (backend_error "delete" (code resp) body)

let delete_multi t keys =
  let body =
    Yojson.Safe.to_string (`List (List.map (fun k -> `String k) keys))
  in
  let uri = Uri.with_path t.base_uri "/delete-multi" in
  let+ resp, rbody = call_retry t ~meth:`POST ~body "delete_multi" uri in
  if not (is_ok resp) then
    raise (backend_error "delete_multi" (code resp) rbody)

let copy t ~src_key ~dst_key () =
  let uri =
    Uri.with_query'
      (Uri.with_path t.base_uri "/copy")
      [("src", src_key); ("dst", dst_key)]
  in
  let+ resp, body = call_retry t ~meth:`POST "copy" uri in
  if not (is_ok resp) then raise (backend_error "copy" (code resp) body)

let list_all t ?max_keys ~prefix () =
  let query =
    [("mode", "all"); ("prefix", prefix)]
    @
      match max_keys with
      | Some n -> [("max_keys", string_of_int n)]
      | None -> []
  in
  let uri = Uri.with_query' (Uri.with_path t.base_uri "/list") query in
  let+ resp, body = call_retry t ~meth:`GET "list_all" uri in
  if is_ok resp then Http_proxy.Wire.entries_of_json body
  else raise (backend_error "list_all" (code resp) body)

let list_directory t ~prefix () =
  let uri =
    Uri.with_query'
      (Uri.with_path t.base_uri "/list")
      [("mode", "dir"); ("prefix", prefix)]
  in
  let+ resp, body = call_retry t ~meth:`GET "list_directory" uri in
  if is_ok resp then Http_proxy.Wire.list_dir_of_json body
  else raise (backend_error "list_directory" (code resp) body)

(* Ask the frontend for the share base URL of [prefix]'s domain. *)
let query_share_url t ~prefix =
  let uri =
    Uri.with_query' (Uri.with_path t.base_uri "/share-url") [("prefix", prefix)]
  in
  let+ resp, body = call_retry t ~meth:`GET "share_url" uri in
  if is_ok resp then (
    match Yojson.Safe.from_string body with
      | exception _ -> None
      | j -> (
          match Yojson.Safe.Util.member "url" j with
            | `String u -> Some u
            | _ -> None))
  else if code resp = 404 then None
  else raise (backend_error "share_url" (code resp) body)

(* The share URL is fixed for the life of the process; query the frontend once and
   memoize the promise (so concurrent callers share the single request). *)
let share_url_op t ~prefix () =
  match t.share_url_cache with
    | Some p -> p
    | None ->
        let p = query_share_url t ~prefix in
        t.share_url_cache <- Some p;
        p

let make ~url ~secret : (module Backend.S) =
  let t = { base_uri = Uri.of_string url; secret; share_url_cache = None } in
  (module struct
    let put ~key ~data () = put t ~key ~data ()
    let get ~key () = get t ~key ()
    let get_opt ~key () = get_opt t ~key ()
    let head_opt ~key () = head_opt t ~key ()
    let delete ~key () = delete t ~key ()
    let delete_multi keys = delete_multi t keys
    let copy ~src_key ~dst_key () = copy t ~src_key ~dst_key ()
    let list_all ?max_keys ~prefix () = list_all t ?max_keys ~prefix ()
    let list_directory ~prefix () = list_directory t ~prefix ()
    let share_url ~prefix () = share_url_op t ~prefix ()
  end)

let spec =
  Backend.
    [
      {
        name = "url";
        label = "Proxy URL (http(s)://host[:port])";
        typ = `String;
        default = None;
        secret = false;
      };
      {
        name = "secret";
        label = "Shared secret";
        typ = `String;
        default = None;
        secret = true;
      };
    ]

let () =
  let req get key =
    match get key with
      | Some v -> v
      | None -> failwith ("http-proxy backend: missing field: " ^ key)
  in
  Backend.register ~spec "http-proxy" (fun get ->
      make ~url:(req get "url") ~secret:(req get "secret"))
