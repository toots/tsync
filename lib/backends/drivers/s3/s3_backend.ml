open Lwt.Syntax
module S3 = Aws_s3_lwt.S3

exception Cancelled = Backend.Cancelled

type t = {
  bucket : string;
  credentials : Aws_s3.Credentials.t;
  endpoint : Aws_s3.Region.endpoint;
  unsigned_payload : bool;
  share_url : string option;
  verify_chunks : bool;
}

let make_t ?endpoint ?(unsigned_payload = false) ?share_url
    ?(verify_chunks = false) ~bucket ~region ~access_key_id ~secret_access_key
    () =
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
  { bucket; credentials; endpoint; unsigned_payload; share_url; verify_chunks }

let string_of_error = function
  | S3.Redirect _ -> "redirect"
  | S3.Throttled -> "throttled"
  | S3.Unknown (code, msg) -> Printf.sprintf "unknown(%d): %s" code msg
  | S3.Failed exn -> Printexc.to_string exn
  | S3.Forbidden -> "forbidden"
  | S3.Not_found -> "not found"

(* B2 (and S3 under load) routinely answers 503, expecting a back off and retry
   rather than a failed operation, and connection-level failures are equally
   transient. Everything else is the bucket's considered answer. *)
let is_transient = function
  | S3.Throttled | S3.Failed _ -> true
  | S3.Redirect _ | S3.Unknown _ | S3.Forbidden | S3.Not_found -> false

let failed op e =
  Backend.failed
    ~kind:(if is_transient e then Backend.Transient else Backend.Permanent)
    ~op (string_of_error e)

(* Raises on a transient error so the shared loop retries it; every other
   outcome, [Not_found] included, comes back for the verb to interpret. *)
let with_retry op f =
  Backend.with_retry ~name:"s3" ~op (fun () ->
      let* res = f () in
      match res with
        | Error e when is_transient e -> Lwt.fail (failed op e)
        | res -> Lwt.return res)

let unwrap op = function
  | Ok v -> v
  | Error e ->
      Log.err "s3 %s: %s" op (string_of_error e);
      raise (failed op e)

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

(* [`If_none_match] is s3's own "only if this key is free": it decides, and
   answers 412 when it declines, so the object is never replaced and the loser
   learns it lost. Emulating it with a HEAD and a PUT would lose races
   silently. *)
let put_if_absent t ~key ~data () =
  let* res =
    with_retry "put_if_absent" (fun () ->
        S3.put ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
          ~unsigned_payload:t.unsigned_payload ~precondition:`If_none_match ~key
          ~data ())
  in
  match res with
    | Ok _ -> Lwt.return data
    (* The precondition failed: somebody else holds the key, and their body is
       the answer. *)
    | Error (S3.Unknown (412, _)) -> get t ~key ()
    | Error e -> raise (failed "put_if_absent" e)

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
        Log.err "s3 get %s: %s" key (string_of_error e);
        raise (failed "get" e)

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
        Log.err "s3 head %s: %s" key (string_of_error e);
        raise (failed "head" e)

let delete t ~key () =
  let+ res =
    with_retry "delete" (fun () ->
        S3.delete ~credentials:t.credentials ~endpoint:t.endpoint
          ~bucket:t.bucket ~key ())
  in
  match res with
    | Ok _ | Error S3.Not_found -> ()
    | Error e -> raise (failed "delete" e)

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
        let result = unwrap "delete_multi" res in
        (* A bulk delete answers 200 and reports what it refused inside the body,
           so the request succeeding says nothing about the objects. This list
           used to be discarded, which made a refusal indistinguishable from a
           delete: {!Gc} discards the main's copy right after this returns, and
           since nothing walks a copy afterwards the keys would stay on it for
           good, under a run that reported a tidy success.

           Classified [Transient] rather than by the code, which is per key and
           not one answer: a batch retried costs a repeat of something idempotent,
           and being wrong the other way strands the objects. *)
        (match
           List.filter
             (fun (e : S3.Delete_multi.error) ->
               not (Backend.absent_code e.S3.Delete_multi.code))
             result.S3.Delete_multi.error
         with
          | [] -> ()
          | first :: _ as refused ->
              raise
                (Backend.failed ~kind:Backend.Transient ~op:"delete_multi"
                   (Printf.sprintf
                      "%d of %d object(s) not deleted; first was %s: %s (%s)"
                      (List.length refused) (List.length here)
                      first.S3.Delete_multi.key first.S3.Delete_multi.code
                      first.S3.Delete_multi.message)));
        go rest
  in
  go keys

let copy t ~src_key ~dst_key () =
  let* data = get t ~key:src_key () in
  put t ~key:dst_key ~data ()

let list_all t ?max_keys ~prefix () =
  (* Reverse accumulation for O(1) prepend: appending each page onto a growing
     list is O(n^2), and this runs over however many objects share the prefix (a
     whole namespace during a resync).

     [max_keys] stops pagination once reached, so a bounded existence check
     costs one small request rather than a full listing. *)
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
              | Error e -> Lwt.fail (failed "ls-cont" e)))
  in
  let* res =
    with_retry "ls" (fun () ->
        S3.ls ~credentials:t.credentials ~endpoint:t.endpoint ~bucket:t.bucket
          ?max_keys ~prefix ())
  in
  match res with
    | Ok (items, cont) -> collect [List.map entry_of items] cont
    | Error e ->
        Log.err "s3 ls %s: %s" prefix (string_of_error e);
        Lwt.fail (failed "ls" e)

let make ?endpoint ?unsigned_payload ?share_url ?verify_chunks ~bucket ~region
    ~access_key_id ~secret_access_key () : (module Backend.S) =
  let t =
    make_t ?endpoint ?unsigned_payload ?share_url ?verify_chunks ~bucket ~region
      ~access_key_id ~secret_access_key ()
  in
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

    (* No chunk size or concurrency opinion: an object store is limited by the
       network and its own concurrency, neither measurable from here.

       [verified] is the operator's word, not something this can observe: what
       checks the chunks runs in the bucket, out of reach of any client. It says
       whether the terraform was applied, and it is asked for rather than assumed
       because the failure it guards is silent — an un-deployed bucket lists no
       markers, and "no markers" would otherwise read as "no corruption". *)
    let capabilities ~prefix:_ () =
      Lwt.return
        {
          Backend.no_caps with
          share_url = t.share_url;
          verified = t.verify_chunks;
        }
  end)

let spec =
  Field_spec.
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
      {
        name = "verifyChunks";
        label =
          "Is the chunk-verifier function deployed for this bucket (terraform \
           chunk_domains)?";
        typ = `Bool;
        default = Some "false";
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
      (* [None] rather than [Some false]: unset must leave the store's own
         default alone. *)
      let unsigned_payload =
        if Field_spec.bool ~default:false (get "unsignedPayload") then Some true
        else None
      in
      let share_url =
        match get "shareUrl" with Some "" | None -> None | s -> s
      in
      let verify_chunks = Field_spec.bool ~default:false (get "verifyChunks") in
      make ?endpoint:(get "endpoint") ?unsigned_payload ?share_url
        ~verify_chunks ~bucket:(req get "bucket") ~region:(req get "region")
        ~access_key_id:(req get "accessKeyId")
        ~secret_access_key:(req get "secretAccessKey")
        ())
