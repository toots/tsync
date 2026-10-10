open Tsync_core
open Tsync_store
open Tsync_http

let p = Contract.p

(* An in-memory bucket speaking the S3 REST API, path-style, which checks each
   request's SigV4 signature as it arrived on the wire. *)
let objects : (string, string * float) Hashtbl.t = Hashtbl.create 64
let bad_signatures = ref 0
let signed = ref 0

let credentials =
  {
    Tsync_s3.S3.access_key = "AKIDTEST";
    secret = "secret/with+odd=chars";
    region = "us-east-1";
  }

let pct_decode s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i < String.length s then
      if s.[i] = '%' && i + 2 < String.length s then (
        Buffer.add_char b
          (Char.chr (int_of_string ("0x" ^ String.sub s (i + 1) 2)));
        go (i + 3))
      else (
        Buffer.add_char b s.[i];
        go (i + 1))
  in
  go 0;
  Buffer.contents b

let query q =
  if q = "" then []
  else
    List.map
      (fun kv ->
        match String.index_opt kv '=' with
          | Some i ->
              ( pct_decode (String.sub kv 0 i),
                pct_decode (String.sub kv (i + 1) (String.length kv - i - 1)) )
          | None -> (pct_decode kv, ""))
      (String.split_on_char '&' q)

(* The verifier re-derives the canonical request from what it received. *)
let check_signature (r : Server.request) =
  let auth =
    Option.value ~default:"" (Codec.header r.headers "authorization")
  in
  let signed_headers =
    match Text.find_from auth "SignedHeaders=" 0 with
      | None -> []
      | Some i ->
          let i = i + String.length "SignedHeaders=" in
          let j = Option.get (Text.find_from auth "," i) in
          String.split_on_char ';' (String.sub auth i (j - i))
  in
  let time =
    match Codec.header r.headers "x-amz-date" with
      | Some d ->
          Scanf.sscanf d "%4d%2d%2dT%2d%2d%2dZ" (fun y mo da h mi s ->
              Ptime.to_float_s
                (Option.get (Ptime.of_date_time ((y, mo, da), ((h, mi, s), 0)))))
      | None -> 0.
  in
  let expected =
    Tsync_s3.S3.authorization credentials ~time ~meth:r.meth ~path:r.path
      ~query:(Tsync_s3.S3.canonical_query (query r.query))
      ~headers:
        (List.map
           (fun h -> (h, Option.value ~default:"" (Codec.header r.headers h)))
           signed_headers)
      ~payload_hash:
        (Option.value ~default:""
           (Codec.header r.headers "x-amz-content-sha256"))
  in
  incr signed;
  if auth <> expected || not (List.mem "host" signed_headers) then
    incr bad_signatures

let xml status body = { Server.status; headers = []; body = String body }
let empty status = { Server.status; headers = []; body = Empty }

let error status code =
  xml status (Printf.sprintf "<Error><Code>%s</Code></Error>" code)

let page_size = 3

(* Keys whose first request was answered with a transient error. *)
let answered_once : (string, unit) Hashtbl.t = Hashtbl.create 4
let etag body = "\"" ^ Digest.to_hex (Digest.string body) ^ "\""

let listing q =
  let prefix = Option.value ~default:"" (List.assoc_opt "prefix" q) in
  let names =
    Hashtbl.fold
      (fun k _ acc -> if String.starts_with ~prefix k then k :: acc else acc)
      objects []
    |> List.sort compare
  in
  let start =
    Option.value ~default:0
      (Option.map int_of_string (List.assoc_opt "continuation-token" q))
  in
  let size =
    min page_size
      (Option.value ~default:page_size
         (Option.map int_of_string (List.assoc_opt "max-keys" q)))
  in
  let page = List.filteri (fun i _ -> i >= start && i < start + size) names in
  xml 200
    ("<ListBucketResult>"
    ^ String.concat ""
        (List.map
           (fun n ->
             let body, t = Hashtbl.find objects n in
             Printf.sprintf
               "<Contents><Key>%s</Key><LastModified>%s</LastModified><ETag>%s</ETag><Size>%d</Size></Contents>"
               (Bucket_xml.escape n)
               (Ptime.to_rfc3339 ~frac_s:3 (Option.get (Ptime.of_float_s t)))
               (Bucket_xml.escape (etag body))
               (String.length body))
           page)
    ^ (if start + size < List.length names then
         Printf.sprintf "<NextContinuationToken>%d</NextContinuationToken>"
           (start + size)
       else "")
    ^ "</ListBucketResult>")

let handler (r : Server.request) read_body =
  check_signature r;
  let q = query r.query in
  let body () = Bigstring.to_string (read_body ~limit:max_int) in
  match (r.meth, String.index_from_opt r.path 1 '/') with
    | "GET", None -> listing q
    | "POST", None when List.mem_assoc "delete" q ->
        let body = body () in
        if
          Codec.header r.headers "content-md5"
          <> Some (Base64.encode_string (Digest.string body))
        then error 400 "InvalidDigest"
        else (
          List.iter
            (fun o ->
              Hashtbl.remove objects (Option.get (Bucket_xml.field o "Key")))
            (Bucket_xml.elements body "Object");
          xml 200 "<DeleteResult/>")
    | meth, Some i -> (
        let name =
          pct_decode (String.sub r.path (i + 1) (String.length r.path - i - 1))
        in
        match (meth, Hashtbl.find_opt objects name) with
          | _, _ when String.ends_with ~suffix:"/skewed" name ->
              error 403 "RequestTimeTooSkewed"
          | _, _
            when String.ends_with ~suffix:"/timed-out-once" name
                 && not (Hashtbl.mem answered_once name) ->
              Hashtbl.replace answered_once name ();
              error 400 "RequestTimeout"
          | _, _
            when String.ends_with ~suffix:"/aborted-once" name
                 && not (Hashtbl.mem answered_once name) ->
              Hashtbl.replace answered_once name ();
              error 409 "OperationAborted"
          | _, _ when String.ends_with ~suffix:"/elsewhere" name ->
              {
                (error 301 "PermanentRedirect") with
                headers = [("x-amz-bucket-region", "eu-west-1")];
              }
          | "PUT", _
            when String.ends_with ~suffix:"/unclaimable" name
                 && Codec.header r.headers "if-none-match" <> None ->
              error 501 "NotImplemented"
          | "PUT", _ -> (
              match Codec.header r.headers "x-amz-copy-source" with
                | Some src -> (
                    let src =
                      let s = pct_decode src in
                      let j = String.index_from s 1 '/' in
                      String.sub s (j + 1) (String.length s - j - 1)
                    in
                    match Hashtbl.find_opt objects src with
                      | Some (b, _) ->
                          Hashtbl.replace objects name (b, Unix.gettimeofday ());
                          xml 200 "<CopyObjectResult/>"
                      | None -> error 404 "NoSuchKey")
                | None ->
                    let body = body () in
                    let lax = String.starts_with ~prefix:"/lax/" r.path in
                    let if_match = Codec.header r.headers "if-match" in
                    if
                      Codec.header r.headers "if-none-match" = Some "*"
                      && (not lax) && Hashtbl.mem objects name
                    then error 412 "PreconditionFailed"
                    else if
                      if_match <> None && (not lax)
                      && not (Hashtbl.mem objects name)
                    then error 404 "NoSuchKey"
                    else if
                      (not lax)
                      && Option.fold ~none:false
                           ~some:(fun m ->
                             m <> etag (fst (Hashtbl.find objects name)))
                           if_match
                    then error 412 "PreconditionFailed"
                    else (
                      Hashtbl.replace objects name (body, Unix.gettimeofday ());
                      empty 200))
          | _, None -> error 404 "NoSuchKey"
          | "DELETE", Some _ ->
              Hashtbl.remove objects name;
              empty 204
          | "HEAD", Some (body, t) ->
              {
                Server.status = 200;
                headers =
                  [("last-modified", Codec.http_date t); ("etag", etag body)];
                body = String body;
              }
          | "GET", Some (body, _) -> (
              match Codec.header r.headers "range" with
                | None -> xml 200 body
                | Some range ->
                    Scanf.sscanf range "bytes=%d-%d" (fun a b ->
                        let size = String.length body in
                        if a >= size then error 416 "InvalidRange"
                        else (
                          let b = min b (size - 1) in
                          {
                            status = 206;
                            headers =
                              [
                                ( "content-range",
                                  Printf.sprintf "bytes %d-%d/%d" a b size );
                              ];
                            body = String (String.sub body a (b - a + 1));
                          })))
          | _ -> empty 405)
    | _ -> empty 400

(* Requests are served on several domains, and a conditional write is a check
   then a write. *)
let bucket_lock = Rt.Fmutex.create ()

let handler r read_body =
  Rt.Fmutex.with_lock bucket_lock (fun () -> handler r read_body)

(* The worked examples of the S3 SigV4 documentation. *)
let vectors () =
  let aws =
    {
      Tsync_s3.S3.access_key = "AKIAIOSFODNN7EXAMPLE";
      secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
      region = "us-east-1";
    }
  in
  let time = 1369353600. and host = "examplebucket.s3.amazonaws.com" in
  let signature ~meth ~path ~query ~headers ~payload_hash =
    let a =
      Tsync_s3.S3.authorization aws ~time ~meth ~path ~query ~headers
        ~payload_hash
    in
    String.sub a (String.rindex a '=' + 1) 64
  in
  let empty = Digestif.SHA256.(to_hex (digest_string "")) in
  p "amz date: %s\n" (Tsync_s3.S3.amz_date time);
  p "GET object: %b\n"
    (signature ~meth:"GET" ~path:"/test.txt" ~query:""
       ~headers:
         [
           ("host", host);
           ("range", "bytes=0-9");
           ("x-amz-content-sha256", empty);
           ("x-amz-date", "20130524T000000Z");
         ]
       ~payload_hash:empty
    = "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41");
  let body = "Welcome to Amazon S3." in
  let hash = Digestif.SHA256.(to_hex (digest_string body)) in
  p "PUT object: %b\n"
    (signature ~meth:"PUT"
       ~path:("/" ^ Tsync_s3.S3.uri_encode ~keep_slash:true "test$file.text")
       ~query:""
       ~headers:
         [
           ("date", "Fri, 24 May 2013 00:00:00 GMT");
           ("host", host);
           ("x-amz-content-sha256", hash);
           ("x-amz-date", "20130524T000000Z");
           ("x-amz-storage-class", "REDUCED_REDUNDANCY");
         ]
       ~payload_hash:hash
    = "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd");
  p "GET bucket: %b\n"
    (signature ~meth:"GET" ~path:"/"
       ~query:(Tsync_s3.S3.canonical_query [("prefix", "J"); ("max-keys", "2")])
       ~headers:
         [
           ("host", host);
           ("x-amz-content-sha256", empty);
           ("x-amz-date", "20130524T000000Z");
         ]
       ~payload_hash:empty
    = "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7");
  p "key encoding: %s\n"
    (Tsync_s3.S3.uri_encode ~keep_slash:true "tsync/d/x/a+b%c d~é")

let () =
  p "== SigV4 (backends/s3 §3)\n";
  vectors ();
  Rt.run_sync (fun () ->
      let server =
        Server.serve [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)] handler
      in
      let port =
        match Server.addresses server with
          | [ADDR_INET (_, p)] -> p
          | _ -> assert false
      in
      let env k =
        Option.bind (Sys.getenv_opt k) (function "" -> None | v -> Some v)
      in
      (* A real service (spec backends/s3 §8) when the variables name one. *)
      let fake_contract =
        match
          ( env "TSYNC_CI_S3_BUCKET",
            env "TSYNC_CI_S3_ACCESS_KEY_ID",
            env "TSYNC_CI_S3_SECRET_ACCESS_KEY" )
        with
          | Some bucket, Some akid, Some secret ->
              let domain_name = Contract.run_scope () in
              prerr_endline
                ("s3_test: against bucket " ^ bucket ^ ", domain " ^ domain_name);
              let opt k field =
                Option.to_list
                  (Option.map (fun v -> (field, Field_spec.S v)) (env k))
              in
              p "\n";
              let real =
                (Option.get (Driver.find "s3")).create ~admission:Uplink.none
                  ~domain:(Domain_name.v domain_name)
                  ~name:"s3"
                  ([
                     ("bucket", Field_spec.S bucket);
                     ("accessKeyId", Field_spec.S akid);
                     ("secretAccessKey", Field_spec.S secret);
                   ]
                  @ opt "TSYNC_CI_S3_ENDPOINT" "endpoint"
                  @ opt "TSYNC_CI_S3_REGION" "region")
              in
              Fun.protect
                ~finally:(fun () -> Contract.cleanup real)
                (fun () -> Contract.run ~domain_name real);
              None
          | _ when Contract.real_required "s3" ->
              prerr_endline
                "s3_test: TSYNC_CI_REQUIRE_REAL names s3 but the bucket or \
                 keys are missing";
              exit 2
          | _ -> Some ()
      in
      let s =
        (Option.get (Driver.find "s3")).create ~admission:Uplink.none
          ~domain:(Domain_name.v "d") ~name:"s3"
          [
            ("bucket", Field_spec.S "b");
            ( "endpoint",
              Field_spec.S (Printf.sprintf "http://127.0.0.1:%d" port) );
            ("accessKeyId", Field_spec.S credentials.access_key);
            ("secretAccessKey", Field_spec.S credentials.secret);
          ]
      in
      Option.iter
        (fun () ->
          p "\n";
          Fun.protect
            ~finally:(fun () -> Contract.cleanup s)
            (fun () -> Contract.run s))
        fake_contract;
      signed := 0;
      let k = Key.v "tsync/d/wire/a+b c%d" in
      s.put k (Bigstring.of_string "x");
      ignore
        (s.get_opt k, s.head_opt k, s.list_prefix (Key.prefix "tsync/d/wire/"));
      s.copy k (Key.v "tsync/d/wire/copy");
      s.delete_multi [k; Key.v "tsync/d/wire/copy"];
      p "\n== s3 wire\n";
      let sum (e : Store.entry option) =
        Option.fold ~none:"none" ~some:Checksum.to_string
          (Option.bind e (fun (e : Store.entry) -> e.checksum))
      in
      let ck = Key.v "tsync/d/wire/sum" in
      s.put ck (Bigstring.of_string "abc");
      p "checksum listed: %s; headed: %s\n"
        (sum (List.nth_opt (s.list_prefix (Key.prefix "tsync/d/wire/")) 0))
        (sum (s.head_opt ck));
      let not_md5 =
        (Option.get (Driver.find "s3")).create ~admission:Uplink.none
          ~domain:(Domain_name.v "d") ~name:"s3"
          [
            ("bucket", Field_spec.S "b");
            ( "endpoint",
              Field_spec.S (Printf.sprintf "http://127.0.0.1:%d" port) );
            ("accessKeyId", Field_spec.S credentials.access_key);
            ("secretAccessKey", Field_spec.S credentials.secret);
            ("etagIsMd5", Field_spec.B false);
          ]
      in
      p "etagIsMd5 false: listed %s; headed %s\n"
        (sum
           (List.nth_opt (not_md5.list_prefix (Key.prefix "tsync/d/wire/")) 0))
        (sum (not_md5.head_opt ck));
      p "a multipart ETag is no MD5: %b\n"
        (Checksum.md5_of_hex "900150983cd24fb0d6963f7d28e17f72-2" = None);
      s.delete ck |> ignore;
      List.iter
        (fun (label, f) ->
          p "%s: %s\n" label
            (match f () with
              | () -> "ok"
              | exception Fail.E f ->
                  Printf.sprintf "%s, %s" (Fail.kind_name f.kind) f.reason))
        [
          ("clock off", fun () -> ignore (s.get_opt (Key.v "tsync/d/skewed")));
          ( "a put the service refuses counts no upload",
            fun () ->
              let sent () =
                match s.traffic with
                  | Some t -> Atomic.get t.uploaded
                  | None -> -1
              in
              let before = sent () in
              (try s.put (Key.v "tsync/d/skewed") (Bigstring.of_string "12345")
               with Fail.E _ -> ());
              if sent () <> before then
                Fail.raise_ Fail.Corrupt "%d bytes counted" (sent () - before)
          );
          ( "a request the service timed out, once",
            fun () -> ignore (s.get_opt (Key.v "tsync/d/timed-out-once")) );
          ( "an operation the service aborted, once",
            fun () -> ignore (s.get_opt (Key.v "tsync/d/aborted-once")) );
          ( "wrong region",
            fun () -> ignore (s.get_opt (Key.v "tsync/d/elsewhere")) );
          ( "claim on a provider without If-None-Match",
            fun () ->
              ignore
                (s.put_if_absent
                   (Key.v "tsync/d/unclaimable")
                   (Bigstring.of_string "x")) );
        ];
      let lax =
        (Option.get (Driver.find "s3")).create ~admission:Uplink.none
          ~domain:(Domain_name.v "lax") ~name:"lax"
          [
            ("bucket", Field_spec.S "lax");
            ( "endpoint",
              Field_spec.S (Printf.sprintf "http://127.0.0.1:%d" port) );
            ("accessKeyId", Field_spec.S credentials.access_key);
            ("secretAccessKey", Field_spec.S credentials.secret);
          ]
      in
      let claim (s : Store.t) name =
        match s.put_if_absent (Key.v name) (Bigstring.of_string name) with
          | Won -> "won"
          | Held _ -> "held"
          | exception Fail.E f -> Fail.kind_name f.kind ^ ", " ^ f.reason
      in
      p "a provider ignoring If-None-Match: %s\n" (claim lax "tsync/lax/first");
      p "and again: %s\n" (claim lax "tsync/lax/second");
      p "a provider honouring it: %s\n" (claim s "tsync/d/wire/claimed");
      let replace (s : Store.t) name =
        let k = Key.v name in
        s.put k (Bigstring.of_string "v1");
        match
          s.put_if_unchanged k (Bigstring.of_string "v2") (s.head_opt k)
        with
          | Written -> "written"
          | Changed -> "changed"
          | exception Fail.E f -> Fail.kind_name f.kind ^ ", " ^ f.reason
      in
      p "a provider ignoring If-Match: %s\n" (replace lax "tsync/lax/replaced");
      p "a provider honouring it: %s\n" (replace s "tsync/d/wire/replaced");
      p "every request signed correctly: %b (%d requests)\n"
        (!bad_signatures = 0) !signed;
      Server.close server)
