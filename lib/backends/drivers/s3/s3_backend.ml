(* The API is functorised over its own notion of a deferred, and the Lwt
   package is that functor already applied -- so this takes the notion rather
   than the application, and the two are pinned to the same type. *)
module Over
    (Io : Io.S)
    (S3io : Aws_s3.Types.Io with type 'a Deferred.t = 'a Io.t)
    (Loop : Retry.LOOP with type 'a io := 'a Io.t)
    (Bounded : Bounded.S with type 'a io := 'a Io.t)
    (Clock : Clock.S with type 'a io := 'a Io.t) =
struct
  module S3 = Aws_s3.S3.Make (S3io)

  module type Store = Backend.S with type 'a io := 'a Io.t

  open Io_syntax.Make (Io)

  type t = {
    bucket : string;
    credentials : Aws_s3.Credentials.t;
    endpoint : Aws_s3.Region.endpoint;
    unsigned_payload : bool;
    share_url : string option;
  }

  let make_t ?endpoint ?(unsigned_payload = false) ?share_url ~bucket ~region
      ~access_key_id ~secret_access_key () =
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
    { bucket; credentials; endpoint; unsigned_payload; share_url }

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
    Retry.failed
      ~kind:(if is_transient e then Retry.Transient else Retry.Permanent)
      ~op (string_of_error e)

  (* Raises on a transient error so the shared loop retries it; every other
     outcome, [Not_found] included, comes back for the verb to interpret. *)
  let with_retry op f =
    Loop.with_retry ~classify:Backend.classify ~name:"s3" ~op (fun () ->
        let* res = f () in
        match res with
          | Error e when is_transient e -> Io.fail (failed op e)
          | res -> Io.return res)

  let unwrap op = function
    | Ok v -> v
    | Error e ->
        Log.err "s3 %s: %s" op (string_of_error e);
        raise (failed op e)

  let entry_of c =
    Backend.
      {
        key = Stored_key.listed c.S3.key;
        size = c.S3.size;
        last_modified = c.S3.last_modified;
        etag = Some c.S3.etag;
      }

  (* A chunk is handed to aws-s3 as it stands rather than copied into a string,
     so its bytes are read for as long as the request runs and must stay valid
     until it answers -- a retry sends the same buffer again. *)
  let put t ~key ~data () =
    let+ res =
      with_retry "put" (fun () ->
          S3.put_bigstring ~credentials:t.credentials ~endpoint:t.endpoint
            ~bucket:t.bucket ~unsigned_payload:t.unsigned_payload ~key ~data ())
    in
    ignore (unwrap "put" res)

  (* The verifier's job bodies are JSON and small enough to stay on the heap. *)
  let put_text t ~key ~data () =
    let+ res =
      with_retry "put" (fun () ->
          S3.put ~credentials:t.credentials ~endpoint:t.endpoint
            ~bucket:t.bucket ~unsigned_payload:t.unsigned_payload ~key ~data ())
    in
    ignore (unwrap "put" res)

  let get t ~key () =
    let+ res =
      with_retry "get" (fun () ->
          S3.get_bigstring ~credentials:t.credentials ~endpoint:t.endpoint
            ~bucket:t.bucket ~key ())
    in
    unwrap "get" res

  (* [`If_none_match] is s3's own "only if this key is free": it decides, and
     answers 412 when it declines, so the object is never replaced and the loser
     learns it lost. Emulating it with a HEAD and a PUT would lose races
     silently. *)
  let put_if_absent t ~key ~data () =
    let* res =
      with_retry "put_if_absent" (fun () ->
          S3.put_bigstring ~credentials:t.credentials ~endpoint:t.endpoint
            ~bucket:t.bucket ~unsigned_payload:t.unsigned_payload
            ~precondition:`If_none_match ~key ~data ())
    in
    match res with
      | Ok _ -> Io.return data
      (* The precondition failed: somebody else holds the key, and their body is
         the answer. *)
      | Error (S3.Unknown (412, _)) -> get t ~key ()
      | Error e -> raise (failed "put_if_absent" e)

  let get_opt t ~key () =
    let+ res =
      with_retry "get" (fun () ->
          S3.get_bigstring ~credentials:t.credentials ~endpoint:t.endpoint
            ~bucket:t.bucket ~key ())
    in
    match res with
      | Ok body -> Some body
      | Error S3.Not_found -> None
      | Error e ->
          Log.err "s3 get %s: %s" key (string_of_error e);
          raise (failed "get" e)

  (* [last] is the index of the final byte, which is why a length of zero has no
     spelling here and the signature rules one out. *)
  let get_range t ~key ~offset ~length () =
    let range = { S3.first = Some offset; last = Some (offset + length - 1) } in
    let+ res =
      with_retry "get_range" (fun () ->
          S3.get_bigstring ~range ~credentials:t.credentials
            ~endpoint:t.endpoint ~bucket:t.bucket ~key ())
    in
    match res with
      | Ok body -> Some (Backend.checked_range ~op:"s3" ~key ~length body)
      | Error S3.Not_found -> None
      | Error e ->
          Log.err "s3 get_range %s: %s" key (string_of_error e);
          raise (failed "get_range" e)

  let head_opt t ~key () =
    let+ res =
      with_retry "head" (fun () ->
          S3.head ~credentials:t.credentials ~endpoint:t.endpoint
            ~bucket:t.bucket ~key ())
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
      | [] -> Io.return ()
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
                  (Retry.failed ~kind:Retry.Transient ~op:"delete_multi"
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
      if enough acc then Io.return (List.concat (List.rev acc))
      else (
        match cont with
          | S3.Ls.Done -> Io.return (List.concat (List.rev acc))
          | S3.Ls.More f -> (
              let* res = with_retry "ls-cont" (fun () -> f ?max_keys ()) in
              match res with
                | Ok (items, next) ->
                    collect (List.map entry_of items :: acc) next
                | Error e -> Io.fail (failed "ls-cont" e)))
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
          Io.fail (failed "ls" e)

  module Shell =
    Object_store.Over (Io) (Bounded) (Clock)
      (struct
        type nonrec t = t

        let put = put
        let put_if_absent = put_if_absent
        let get = get
        let get_opt = get_opt
        let get_range = get_range
        let head_opt = head_opt
        let delete = delete
        let delete_multi = delete_multi
        let copy = copy
        let list_all = list_all
        let put_text = put_text
        let share_url t = t.share_url
      end)

  let make ?endpoint ?unsigned_payload ?share_url ~bucket ~region ~access_key_id
      ~secret_access_key () : (module Store) =
    let t =
      make_t ?endpoint ?unsigned_payload ?share_url ~bucket ~region
        ~access_key_id ~secret_access_key ()
    in
    Shell.make t

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
      ]
end
