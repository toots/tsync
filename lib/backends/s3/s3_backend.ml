open Lwt.Syntax
module S3 = Aws_s3_lwt.S3

exception Cancelled = Backend.Cancelled

type t = {
  bucket : string;
  credentials : Aws_s3.Credentials.t;
  endpoint : Aws_s3.Region.endpoint;
  unsigned_payload : bool;
}

let make_t ?endpoint ?(unsigned_payload = false) ~bucket ~region ~access_key_id
    ~secret_access_key () =
  let credentials =
    Aws_s3.Credentials.make ~access_key:access_key_id
      ~secret_key:secret_access_key ()
  in
  let region =
    match endpoint with
      | Some host -> Aws_s3.Region.vendor ~region_name:region ~host ()
      | None -> Aws_s3.Region.of_string region
  in
  let endpoint = Aws_s3.Region.endpoint ~inet:`V4 ~scheme:`Https region in
  { bucket; credentials; endpoint; unsigned_payload }

let string_of_error = function
  | S3.Redirect _ -> "redirect"
  | S3.Throttled -> "throttled"
  | S3.Unknown (code, msg) -> Printf.sprintf "unknown(%d): %s" code msg
  | S3.Failed exn -> Printexc.to_string exn
  | S3.Forbidden -> "forbidden"
  | S3.Not_found -> "not found"

let s3_eio msg = Unix.Unix_error (Unix.EIO, "s3", msg)

(* B2 (and S3 under load) routinely answers 503: the client is expected to back
   off and retry, not fail the operation. Connection-level failures are equally
   transient — whether the client surfaces them as [S3.Failed] or raises them
   outright (a DNS "Failed to resolve host", a dropped socket, a TLS reset). Both
   forms are retried with exponential backoff and jitter, capped per attempt and
   in attempt count; only [Cancelled] is never retried. *)
let max_attempts = 8

let is_transient = function
  | S3.Throttled | S3.Failed _ -> true
  | S3.Redirect _ | S3.Unknown _ | S3.Forbidden | S3.Not_found -> false

let with_retry op f =
  let rec go attempt =
    let* outcome =
      Lwt.catch
        (fun () ->
          let+ res = f () in
          `Ret res)
        (fun exn -> Lwt.return (`Raised exn))
    in
    let retry reason =
      let backoff = Float.min 20. (0.5 *. (2. ** float_of_int (attempt - 1))) in
      let delay = backoff *. (0.5 +. Random.float 1.0) in
      Log.warn "s3 %s: %s; retrying (%d/%d) in %.1fs" op reason attempt
        max_attempts delay;
      let* () = Lwt_unix.sleep delay in
      go (attempt + 1)
    in
    match outcome with
      | `Ret (Error e) when attempt < max_attempts && is_transient e ->
          retry (string_of_error e)
      | `Ret res -> Lwt.return res
      | `Raised Cancelled -> Lwt.fail Cancelled
      | `Raised exn when attempt < max_attempts ->
          retry (Printexc.to_string exn)
      | `Raised exn -> Lwt.fail exn
  in
  go 1

let unwrap op = function
  | Ok v -> v
  | Error e ->
      let msg = string_of_error e in
      Log.err "s3 %s: %s" op msg;
      raise (s3_eio msg)

let entry_of c =
  Backend.
    { key = c.S3.key; size = c.S3.size; last_modified = c.S3.last_modified }

let put t ~key ~data () =
  let+ res =
    with_retry "put" (fun () ->
        S3.put ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
          ~unsigned_payload:t.unsigned_payload ~key ~data ())
  in
  ignore (unwrap "put" res)

let get t ~key () =
  let+ res =
    with_retry "get" (fun () ->
        S3.get ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
          ~key ())
  in
  unwrap "get" res

let get_opt t ~key () =
  let+ res =
    with_retry "get" (fun () ->
        S3.get ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
          ~key ())
  in
  match res with
    | Ok body -> Some body
    | Error S3.Not_found -> None
    | Error e ->
        let msg = string_of_error e in
        Log.err "s3 get %s: %s" key msg;
        raise (s3_eio msg)

let head_opt t ~key () =
  let+ res =
    with_retry "head" (fun () ->
        S3.head ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
          ~key ())
  in
  match res with
    | Ok c -> Some (entry_of c)
    | Error S3.Not_found -> None
    | Error e ->
        let msg = string_of_error e in
        Log.err "s3 head %s: %s" key msg;
        raise (s3_eio msg)

let delete t ~key () =
  let+ res =
    with_retry "delete" (fun () ->
        S3.delete ~credentials:t.credentials ~endpoint:t.endpoint
          ~bucket:t.bucket ~key ())
  in
  match res with
    | Ok _ | Error S3.Not_found -> ()
    | Error e -> raise (s3_eio (string_of_error e))

let delete_multi t keys =
  let open S3.Delete_multi in
  let rec go = function
    | [] -> Lwt.return_unit
    | batch ->
        let n = min 1000 (List.length batch) in
        let here = List.filteri (fun i _ -> i < n) batch in
        let rest = List.filteri (fun i _ -> i >= n) batch in
        let objects = List.map (fun key -> { key; version_id = None }) here in
        let* res =
          with_retry "delete_multi" (fun () ->
              S3.delete_multi ~credentials:t.credentials ~endpoint:t.endpoint
                ~bucket:t.bucket ~objects ())
        in
        let (_ : S3.Delete_multi.result) = unwrap "delete_multi" res in
        go rest
  in
  go keys

let copy t ~src_key ~dst_key () =
  let* data = get t ~key:src_key () in
  put t ~key:dst_key ~data ()

let list_all t ?max_keys ~prefix () =
  (* Accumulate pages in reverse (prepend, O(1) each) rather than appending
     each page onto a growing list (O(page count) each, so O(n^2) overall
     across a large prefix) — this runs unbounded over however many objects
     share the prefix, e.g. the full chunk store during GC.

     [max_keys] caps how many entries we return and stops pagination once
     reached, so a bounded existence check ("does this prefix hold anything?")
     costs a single small request instead of a full recursive listing. *)
  let enough acc =
    match max_keys with
      | None -> false
      | Some n -> List.length (List.concat acc) >= n
  in
  let rec collect acc cont =
    if enough acc then Lwt.return (List.concat (List.rev acc))
    else (
      match cont with
        | S3.Ls.Done -> Lwt.return (List.concat (List.rev acc))
        | S3.Ls.More f -> (
            let* res = with_retry "ls-cont" (fun () -> f ?max_keys ()) in
            match res with
              | Ok (items, next) ->
                  collect (List.map entry_of items :: acc) next
              | Error e -> Lwt.fail (s3_eio (string_of_error e))))
  in
  let* res =
    with_retry "ls" (fun () ->
        S3.ls ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
          ?max_keys ~prefix ())
  in
  match res with
    | Ok (items, cont) -> collect [List.map entry_of items] cont
    | Error e ->
        let msg = string_of_error e in
        Log.err "s3 ls %s: %s" prefix msg;
        Lwt.fail (s3_eio msg)

let list_directory t ~prefix () =
  let prefix_len = String.length prefix in
  let+ all = list_all t ~prefix () in
  let dirs = Hashtbl.create 16 in
  let files = ref [] in
  List.iter
    (fun (e : Backend.file_entry) ->
      if String.length e.key <= prefix_len then ()
      else begin
        let rest =
          String.sub e.key prefix_len (String.length e.key - prefix_len)
        in
        match String.index_opt rest '/' with
          | None -> files := e :: !files
          | Some i -> (
              let dir_name = String.sub rest 0 i in
              let mtime =
                if i = String.length rest - 1 then Some e.last_modified
                else None
              in
              match Hashtbl.find_opt dirs dir_name with
                | None -> Hashtbl.add dirs dir_name mtime
                | Some None when mtime <> None ->
                    Hashtbl.replace dirs dir_name mtime
                | Some _ -> ())
      end)
    all;
  let subdirs = Hashtbl.fold (fun k mtime acc -> (k, mtime) :: acc) dirs [] in
  (List.rev !files, List.sort (fun (a, _) (b, _) -> String.compare a b) subdirs)

let make ?endpoint ?unsigned_payload ~bucket ~region ~access_key_id
    ~secret_access_key () : (module Backend.S) =
  let t =
    make_t ?endpoint ?unsigned_payload ~bucket ~region ~access_key_id
      ~secret_access_key ()
  in
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
  end)

let spec =
  Backend.
    [
      {
        name = "bucket";
        label = "S3 bucket";
        typ = `String;
        default = None;
        secret = false;
      };
      {
        name = "region";
        label = "AWS region";
        typ = `String;
        default = Some "us-east-1";
        secret = false;
      };
      {
        name = "endpoint";
        label = "Custom endpoint (blank for AWS)";
        typ = `String;
        default = Some "";
        secret = false;
      };
      {
        name = "accessKeyId";
        label = "AWS Access Key ID";
        typ = `String;
        default = None;
        secret = false;
      };
      {
        name = "secretAccessKey";
        label = "AWS Secret Access Key";
        typ = `String;
        default = None;
        secret = true;
      };
      {
        name = "unsignedPayload";
        label = "Skip per-chunk payload signing (lower CPU, safe over TLS)?";
        typ = `Bool;
        default = Some "false";
        secret = false;
      };
      {
        name = "shareUrl";
        label = "Share Lambda URL (blank if this bucket has no share service)";
        typ = `String;
        default = Some "";
        secret = false;
      };
    ]

let () =
  let req get key =
    match get key with
      | Some v -> v
      | None -> failwith ("s3 backend: missing field: " ^ key)
  in
  Backend.register ~spec "s3" (fun get ->
      let unsigned_payload =
        match get "unsignedPayload" with
          | Some ("true" | "1") -> Some true
          | Some _ | None -> None
      in
      make ?endpoint:(get "endpoint") ?unsigned_payload
        ~bucket:(req get "bucket") ~region:(req get "region")
        ~access_key_id:(req get "accessKeyId")
        ~secret_access_key:(req get "secretAccessKey")
        ())
