open Tsync_core
open Tsync_store
open Tsync_http

let p = Contract.p

(* An in-memory bucket speaking the JSON API and the XML bulk delete. *)
let objects : (string, string * float) Hashtbl.t = Hashtbl.create 64
let requests = ref []

(* Each write of a name gets a new generation, as GCS gives it. *)
let generations : (string, int) Hashtbl.t = Hashtbl.create 64
let next_generation = ref 1000

let store name v =
  incr next_generation;
  Hashtbl.replace generations name !next_generation;
  Hashtbl.replace objects name v

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
  List.filter_map
    (fun kv ->
      match String.index_opt kv '=' with
        | Some i ->
            Some
              ( String.sub kv 0 i,
                pct_decode (String.sub kv (i + 1) (String.length kv - i - 1)) )
        | None -> None)
    (String.split_on_char '&' q)

let meta name (body, t) =
  `Assoc
    [
      ("name", `String name);
      ("size", `String (string_of_int (String.length body)));
      ( "updated",
        `String (Ptime.to_rfc3339 ~frac_s:3 (Option.get (Ptime.of_float_s t)))
      );
      ("etag", `String "CJ+d4a/x5+8CEAE=");
      ( "generation",
        `String
          (string_of_int
             (Option.value ~default:0 (Hashtbl.find_opt generations name))) );
      ("md5Hash", `String (Base64.encode_string (Digest.string body)));
    ]

let json j =
  { Server.status = 200; headers = []; body = String (Yojson.Safe.to_string j) }

let empty status = { Server.status; headers = []; body = Empty }
let page_size = 3

let handler (r : Server.request) read_body =
  requests := (r.meth ^ " " ^ r.path) :: !requests;
  let q = query r.query in
  match (r.meth, String.split_on_char '/' r.path) with
    | "POST", [""; "upload"; "storage"; "v1"; "b"; _; "o"] -> (
        let name = List.assoc "name" q
        and body = Bigstring.to_string (read_body ~limit:max_int) in
        let current =
          Option.value ~default:0 (Hashtbl.find_opt generations name)
        in
        let current = if Hashtbl.mem objects name then current else 0 in
        match List.assoc_opt "ifGenerationMatch" q with
          | Some g when g <> string_of_int current -> empty 412
          | _ ->
              store name (body, Unix.gettimeofday ());
              json (meta name (body, 0.)))
    | "GET", [""; "storage"; "v1"; "b"; _; "o"] ->
        let prefix = Option.value ~default:"" (List.assoc_opt "prefix" q) in
        let names =
          Hashtbl.fold
            (fun k _ acc ->
              if String.starts_with ~prefix k then k :: acc else acc)
            objects []
          |> List.sort compare
        in
        let start =
          Option.value ~default:0
            (Option.map int_of_string (List.assoc_opt "pageToken" q))
        in
        let page =
          List.filteri (fun i _ -> i >= start && i < start + page_size) names
        in
        json
          (`Assoc
             (( "items",
                `List (List.map (fun n -> meta n (Hashtbl.find objects n)) page)
              )
             ::
             (if start + page_size < List.length names then
                [("nextPageToken", `String (string_of_int (start + page_size)))]
              else [])))
    | ( "POST",
        [""; "storage"; "v1"; "b"; _; "o"; src; "rewriteTo"; "b"; _; "o"; dst] )
      -> (
        match Hashtbl.find_opt objects (pct_decode src) with
          | Some (body, _) ->
              store (pct_decode dst) (body, Unix.gettimeofday ());
              json (`Assoc [("done", `Bool true)])
          | None -> empty 404)
    | meth, [""; "storage"; "v1"; "b"; _; "o"; k] -> (
        let name = pct_decode k in
        match (meth, Hashtbl.find_opt objects name) with
          | _, None -> empty 404
          | "DELETE", Some _ ->
              Hashtbl.remove objects name;
              empty 204
          | "GET", Some ((body, _) as o) ->
              if List.assoc_opt "alt" q <> Some "media" then json (meta name o)
              else (
                match Codec.header r.headers "range" with
                  | None -> { status = 200; headers = []; body = String body }
                  | Some range ->
                      Scanf.sscanf range "bytes=%d-%d" (fun a b ->
                          let size = String.length body in
                          if a >= size then empty 416
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
    | "POST", [""; _] when r.query = "delete" ->
        let body = Bigstring.to_string (read_body ~limit:max_int) in
        if
          Codec.header r.headers "content-md5"
          <> Some (Base64.encode_string (Digest.string body))
        then empty 400
        else (
          let rec keys from acc =
            match Text.find_from body "<Key>" from with
              | None -> acc
              | Some i ->
                  let j = Option.get (Text.find_from body "</Key>" i) in
                  keys j (String.sub body (i + 5) (j - i - 5) :: acc)
          in
          List.iter
            (fun k ->
              Hashtbl.remove objects
                (List.fold_left
                   (fun k (sub, by) -> Text.replace_all ~sub ~by k)
                   k
                   [
                     ("&lt;", "<");
                     ("&gt;", ">");
                     ("&quot;", "\"");
                     ("&apos;", "'");
                     ("&amp;", "&");
                   ]))
            (keys 0 []);
          { status = 200; headers = []; body = String "<DeleteResult/>" })
    | _ -> empty 400

let () =
  Rt.run_sync (fun () ->
      let server =
        Server.serve [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)] handler
      in
      let port =
        match Server.addresses server with
          | [ADDR_INET (_, p)] -> p
          | _ -> assert false
      in
      let fake =
        [
          ("bucket", Field_spec.S "b");
          ("endpoint", Field_spec.S (Printf.sprintf "http://127.0.0.1:%d" port));
        ]
      in
      let fields, domain_name =
        match
          ( Sys.getenv_opt "TSYNC_CI_GCS_BUCKET",
            Sys.getenv_opt "TSYNC_CI_GCS_SERVICE_ACCOUNT_KEY" )
        with
          | Some b, Some key when b <> "" && key <> "" ->
              if Tsync_http.Transport.available () = [] then (
                prerr_endline
                  "gcs_test: a real bucket needs TLS, and none is linked";
                exit 2);
              let run =
                Option.value
                  ~default:(string_of_int (Unix.getpid ()))
                  (Sys.getenv_opt "GITHUB_RUN_ID")
                ^ "-"
                ^ Option.value ~default:"0"
                    (Sys.getenv_opt "GITHUB_RUN_ATTEMPT")
              in
              prerr_endline
                ("gcs_test: against bucket " ^ b ^ ", domain ci-" ^ run);
              ( [
                  ("bucket", Field_spec.S b);
                  ("serviceAccountKey", Field_spec.S key);
                ],
                "ci-" ^ run )
          | _ when Contract.real_required "gcs" ->
              prerr_endline
                "gcs_test: TSYNC_CI_REQUIRE_REAL names gcs but the bucket or \
                 key is missing";
              exit 2
          | _ -> (fake, "d")
      in
      let s =
        (Option.get (Driver.find "gcs")).create ~admission:Uplink.none
          ~domain:(Domain_name.v domain_name)
          ~name:"gcs" fields
      in
      Fun.protect
        ~finally:(fun () -> Contract.cleanup s)
        (fun () -> Contract.run ~domain_name s);
      p "\n== gcs wire (backends/gcs §6)\n";
      if fields == fake then (
        let k = Key.v "tsync/d/wire/x" in
        s.put k (Bigstring.of_string "abc");
        let listed = s.list_prefix (Key.prefix "tsync/d/wire/") in
        let headed = s.head_opt k in
        let show (e : Store.entry option) =
          match e with
            | Some e ->
                Printf.sprintf "etag %s checksum %s"
                  (Option.value ~default:"none" e.etag)
                  (Option.fold ~none:"none" ~some:Checksum.to_string e.checksum)
            | None -> "none"
        in
        p "listed: %s\nheaded: %s\nthe etag is the generation: %b\n"
          (show (List.nth_opt listed 0))
          (show headed)
          (Option.bind headed (fun e -> e.etag)
          = Option.map string_of_int
              (Hashtbl.find_opt generations "tsync/d/wire/x"));
        s.put k (Bigstring.of_string "abd");
        p "a rewrite changes the etag: %b\n"
          ((Option.get (s.head_opt k)).etag <> (Option.get headed).etag));
      p "segment: %s | %s\n"
        (Tsync_gcs.Gcs.segment "tsync/d/.chunks/aabb-ccdd")
        (Tsync_gcs.Gcs.segment "a-b_c.d~e");
      List.iter
        (fun t ->
          p "rfc3339 %s: %s\n" t
            (try Printf.sprintf "%.3f" (Tsync_gcs.Gcs.rfc3339 t)
             with Fail.E f -> Fail.kind_name f.kind))
        [
          "1970-01-01T00:00:00.000Z";
          "2001-09-09T01:46:40Z";
          "2001-09-09T03:46:40+02:00";
          "garbage";
        ];
      p "delete body: %s\n" (Bucket_xml.delete_body ["a/x"; "a/y"; "<&>\"'"]);
      p "no refusals: %d\n"
        (List.length (Bucket_xml.delete_errors "<DeleteResult/>"));
      List.iter
        (fun (c, k) -> p "refusal %s %s\n" c k)
        (Bucket_xml.delete_errors
           "<DeleteResult><Error><Key>a&amp;b&#39;&#x2713;&bogus;</Key><Code>AccessDenied</Code></Error><Error><Key>c</Key><Code>NoSuchKey</Code></Error></DeleteResult>");
      Server.close server)
