open Tsync_core
open Tsync_http
module W = Tsync_http_proxy_client.Proxy_wire
module P = Tsync_owner.Protocol

type route = {
  name : string;
  domain : Domain_name.t;
  secret : string;
  read_only : bool;
  takes : bool;
  chunk : int;
  owner : string;
}

let max_upload_size = 64 * 1024 * 1024 * 1024
let max_uploads = 8
let upload_free_floor = 2 * 1024 * 1024 * 1024
let upload_resume_ttl = 86400.

type committed = { content_id : string; path : string; size : int }

type record = {
  domain : string;
  path : string;
  created : int option;
  base : string option;
  length : int option;  (** the declared total, once known *)
  committed : committed option;
}

type t = {
  dir : string;
  routes : route list;
  count : string -> int -> unit;
  receiving : (string, unit) Hashtbl.t;
  lock : Mutex.t;
}

let create ~dir ~count routes =
  Fs.mkdir_p ~perm:0o700 dir;
  { dir; routes; count; receiving = Hashtbl.create 8; lock = Mutex.create () }

let takes t domain =
  List.exists (fun r -> r.takes && Domain_name.equal r.domain domain) t.routes

let spool t id = Filename.concat t.dir id
let record_path t id = Filename.concat t.dir (id ^ ".json")

let received t id =
  match Unix.stat (spool t id) with
    | s -> s.st_size
    | exception Unix.Unix_error (ENOENT, _, _) -> 0

let record_to_json r : Yojson.Safe.t =
  let opt k f = Option.fold ~none:[] ~some:(fun v -> [(k, f v)]) in
  `Assoc
    ([("domain", `String r.domain); ("path", `String r.path)]
    @ opt "created" (fun n -> `Int n) r.created
    @ opt "base" (fun s -> `String s) r.base
    @ opt "length" (fun n -> `Int n) r.length
    @ opt "committed"
        (fun c ->
          `Assoc
            [
              ("contentId", `String c.content_id);
              ("path", `String c.path);
              ("size", `Int c.size);
            ])
        r.committed)

let record_of_json j =
  let open Yojson.Safe.Util in
  let int_opt k = member k j |> to_int_option in
  let str_opt k = member k j |> to_string_option in
  {
    domain = member "domain" j |> to_string;
    path = member "path" j |> to_string;
    created = int_opt "created";
    base = str_opt "base";
    length = int_opt "length";
    committed =
      (match member "committed" j with
        | `Null -> None
        | c ->
            Some
              {
                content_id = member "contentId" c |> to_string;
                path = member "path" c |> to_string;
                size = member "size" c |> to_int;
              });
  }

let save t id r =
  Fs.durable_replace ~perm:0o600 (record_path t id)
    (Yojson.Safe.to_string (record_to_json r))

let load t id =
  match Yojson.Safe.from_file (record_path t id) with
    | j -> ( try Some (record_of_json j) with _ -> None)
    | exception _ -> None

let remove t id =
  List.iter
    (fun p -> try Unix.unlink p with Unix.Unix_error _ -> ())
    [spool t id; record_path t id]

let header (r : Server.request) k = Codec.header r.headers k

(* wire §5.7: either draft's spelling; neither header means complete. *)
let complete (r : Server.request) =
  not
    (header r "upload-complete" = Some "?0"
    || header r "upload-incomplete" = Some "?1")

let interop (r : Server.request) =
  match header r "upload-draft-interop-version" with
    | Some v -> [("upload-draft-interop-version", v)]
    | None -> []

let answer ?(headers = []) status = { Server.status; headers; body = Empty }

let refused t status msg =
  t.count "uploadRefused" 1;
  Server.text status msg

let offset_headers n complete =
  [
    ("upload-offset", string_of_int n);
    ("upload-complete", if complete then "?1" else "?0");
    ("upload-incomplete", if complete then "?0" else "?1");
    ("cache-control", "no-store");
  ]

let committed_headers c =
  offset_headers c.size true
  @ [
      ("x-tsync-content-id", c.content_id);
      ("x-tsync-path", W.escape_value c.path);
    ]

(* One request receives into an upload at a time, and at most [max_uploads]
   receive at once. *)
let hold t id f =
  let taken =
    Mutex.protect t.lock (fun () ->
        if Hashtbl.mem t.receiving id then `Busy
        else if Hashtbl.length t.receiving >= max_uploads then `Full
        else (
          Hashtbl.replace t.receiving id ();
          `Held))
  in
  match taken with
    | `Busy -> refused t 409 "upload in progress"
    | `Full -> refused t 503 "busy"
    | `Held ->
        Fun.protect
          ~finally:(fun () ->
            Mutex.protect t.lock (fun () -> Hashtbl.remove t.receiving id))
          f

(* Appends the body at the spool's end; the spool's size is the offset, so a
   connection that drops leaves exactly what arrived. *)
let receive t id (r : Server.request) ~limit =
  let fd = Unix.openfile (spool t id) [O_WRONLY; O_CREAT; O_CLOEXEC] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) @@ fun () ->
  let off = ref (Unix.fstat fd).st_size in
  r.stream_body ~limit (fun piece ->
      let len = Bigstring.length piece in
      Fs.pwrite_all fd piece ~boff:0 ~len ~off:!off;
      off := !off + len;
      t.count "uploadBytes" len)

(* 08 §2.3: the digest an upload of the file with the domain's chunk size
   yields. *)
let content_id route path =
  let size = (Unix.stat path).st_size in
  let cs = route.chunk in
  let body = if size = 0 then Bigstring.empty else Fs.map_file path in
  Fun.protect ~finally:(fun () -> Fs.drop_mapped_pages body) @@ fun () ->
  let keys =
    List.init (Chunking.manifest_count ~size ~cs) (fun i ->
        let len = if size = 0 then 0 else Chunking.length ~size ~cs i in
        Chunk_key.of_bigstring ~off:(i * cs) ~len body)
  in
  (fst (Manifest.digest_of ~size ~cs keys), size)

let child route parent_ref name =
  match
    P.call ~domain:route.name route.owner
      (P.Stat (P.Child { parent_ref; name }))
  with
    | row -> Some row
    | exception Fail.E f when f.kind = Absent -> None

(* §A4.8 step 1: the parent folders, made where absent. *)
let folder route dirs =
  List.fold_left
    (fun parent_ref name ->
      match child route parent_ref name with
        | Some { kind = `Dir; ref_; _ } -> ref_
        | Some _ -> Fail.raise_ Exists "%s is not a folder" name
        | None ->
            (P.call ~domain:route.name route.owner
               (P.Mkdir
                  {
                    at = { parent_ref; name };
                    exclusive = false;
                    aside = false;
                  }))
              .item
              .ref_)
    "root" dirs

let commit t route id r =
  let file = spool t id in
  let h1, size = content_id route file in
  let rec split = function
    | [] -> ([], "")
    | [name] -> ([], name)
    | dir :: rest ->
        let dirs, name = split rest in
        (dir :: dirs, name)
  in
  let dirs, name = split (String.split_on_char '/' r.path) in
  let parent_ref = folder route dirs in
  let at name = String.concat "/" (dirs @ [name]) in
  let path =
    match child route parent_ref name with
      | Some row when row.content_id = Some h1 -> r.path
      | _ -> (
          let w =
            P.call ~bulk:true ~domain:route.name route.owner
              (P.Write
                 {
                   at = P.Child { parent_ref; name };
                   staging = file;
                   created = r.created;
                   base = r.base;
                   exclusive = r.base = None;
                   aside = false;
                   await = false;
                 })
          in
          match w.aside with Some row -> at row.name | None -> r.path)
  in
  let c = { content_id = h1; path; size } in
  (try Unix.unlink file with Unix.Unix_error _ -> ());
  save t id { r with committed = Some c };
  c

let committed_answer c = answer 201 ~headers:(committed_headers c)

(* wire §5.7: [exists] is the client's to resolve; an owner not answering,
   or failing for now, leaves the spool for a later commit. *)
let commit_answer t route id r =
  match commit t route id r with
    | c ->
        t.count "uploadCommitted" 1;
        committed_answer c
    | exception e when not (Rt.is_cancelled e) ->
        let f = Fail.classify e in
        Log.info "upload into %s: %s" route.name (Fail.to_string f);
        if Fail.retryable f.kind || f.kind = Unexplained || f.kind = Deadline
        then refused t 503 f.reason
        else
          {
            (refused t 409 f.reason) with
            headers =
              [
                ("content-type", "text/plain; charset=utf-8");
                ( "x-tsync-kind",
                  Option.value ~default:"other" (Fail.wire_kind f.kind) );
              ];
          }

let valid_path p =
  p <> ""
  && List.for_all
       (fun leaf -> leaf <> ".tsync-ext" && Names.valid_leaf leaf)
       (String.split_on_char '/' p)

(* security §11: the spool keeps [upload_free_floor] after every incomplete
   upload's remaining bytes. *)
let room t n =
  let owed =
    Array.fold_left
      (fun owed f ->
        match Filename.chop_suffix_opt ~suffix:".json" f with
          | None -> owed
          | Some id -> (
              match load t id with
                | Some { length = Some l; committed = None; _ } ->
                    owed + max 0 (l - received t id)
                | _ -> owed))
      0
      (try Sys.readdir t.dir with Sys_error _ -> [||])
  in
  match Fs.disk_space t.dir with
    | Some s -> Int64.to_int s.available - owed - n >= upload_free_floor
    | None -> true

let options t =
  match List.filter (fun r -> r.takes) t.routes with
    | [] -> answer 501
    | _ -> answer 200 ~headers:[("upload-limit", string_of_int max_upload_size)]

(* wire §5.7: everything is checked before a body byte is read. *)
let creation t (r : Server.request) =
  let params = Option.value ~default:[("", "")] (W.parse_query r.query) in
  let param k = List.assoc_opt k params in
  let route =
    Option.bind (param "domain") (fun d ->
        List.find_opt (fun route -> route.name = d) t.routes)
  in
  let signed route =
    match header r "x-tsync-upload" with
      | None -> false
      | Some h ->
          let now = Unix.gettimeofday () in
          let target = r.path ^ "?" ^ W.canonical_query params in
          W.upload_verifies ~now ~secret:route.secret ~target h
          || W.upload_verifies ~now ~secret:route.secret ~target:r.target h
  in
  let allowed = ["domain"; "path"; "created"; "base"] in
  match route with
    | None -> refused t 401 "unauthorized"
    | Some route when not (signed route) -> refused t 401 "unauthorized"
    | Some route when not route.takes -> refused t 404 "not found"
    | Some route when route.read_only -> refused t 403 "read-only domain"
    | Some route -> (
        let created =
          Option.map
            (fun s ->
              if s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s
              then int_of_string_opt s
              else None)
            (param "created")
        in
        let base = param "base" in
        match (param "path", r.body_length) with
          | Some path, `Length n
            when List.for_all (fun (k, _) -> List.mem k allowed) params
                 && valid_path path && created <> Some None
                 && (match base with
                   | Some b -> b <> "" && String.for_all Names.is_hexlower b
                   | None -> true)
                 && n >= 0 ->
              let length = if complete r then Some n else None in
              if n > max_upload_size then refused t 413 "too large"
              else if not (room t n) then refused t 503 "no space"
              else (
                let id = Ids.hex (Ids.urandom 16) in
                let record =
                  {
                    domain = route.name;
                    path;
                    created = Option.join created;
                    base;
                    length;
                    committed = None;
                  }
                in
                save t id record;
                t.count "uploadStarted" 1;
                match
                  hold t id (fun () ->
                      r.interim 104 (("location", "upload/r/" ^ id) :: interop r);
                      receive t id r ~limit:n;
                      if complete r then commit_answer t route id record
                      else
                        answer 201
                          ~headers:
                            (("location", "upload/r/" ^ id)
                             :: offset_headers (received t id) false
                            @ interop r))
                with
                  | response -> response
                  | exception Server.Body_too_large -> refused t 413 "too large")
          | _ -> refused t 400 "bad request")

let upload_id rest =
  if String.length rest = 32 && String.for_all Names.is_hexlower rest then
    Some rest
  else None

let route_of t (r : record) =
  List.find_opt (fun route -> route.name = r.domain) t.routes

let on_upload t (r : Server.request) id =
  match (load t id, Option.bind (load t id) (route_of t)) with
    | None, _ | _, None -> Server.text 404 "not found"
    | Some record, Some route -> (
        match (r.meth, record.committed) with
          | "HEAD", Some c ->
              answer 204 ~headers:(committed_headers c @ interop r)
          | "HEAD", None ->
              answer 204
                ~headers:(offset_headers (received t id) false @ interop r)
          | "DELETE", _ ->
              remove t id;
              answer 204
          | "PATCH", Some c -> committed_answer c
          | "PATCH", None -> (
              let at = received t id in
              match
                ( Option.bind (header r "upload-offset") int_of_string_opt,
                  r.body_length )
              with
                | Some o, _ when o <> at ->
                    answer 409 ~headers:(offset_headers at false)
                | Some _, `Length n when n >= 0 ->
                    let total =
                      Option.value ~default:max_upload_size record.length
                    in
                    if at + n > total then refused t 413 "too large"
                    else (
                      match
                        hold t id (fun () ->
                            t.count "uploadResumed" 1;
                            receive t id r ~limit:n;
                            let record =
                              if complete r && record.length = None then (
                                let r =
                                  { record with length = Some (received t id) }
                                in
                                save t id r;
                                r)
                              else record
                            in
                            if complete r then commit_answer t route id record
                            else
                              answer 204
                                ~headers:(offset_headers (received t id) false))
                      with
                        | response -> response
                        | exception Server.Body_too_large ->
                            refused t 413 "too large")
                | _ -> refused t 400 "bad request")
          | _ -> Server.text 405 "method not allowed")

let handle t (r : Server.request) =
  let prefix = "/upload/r/" in
  if r.path = "/upload" then
    Some
      (match r.meth with
        | "OPTIONS" -> options t
        | "POST" -> creation t r
        | _ -> Server.text 405 "method not allowed")
  else if String.starts_with ~prefix r.path then (
    let rest =
      String.sub r.path (String.length prefix)
        (String.length r.path - String.length prefix)
    in
    Some
      (match upload_id rest with
        | Some id -> on_upload t r id
        | None -> Server.text 404 "not found"))
  else None

(* §A4.8: an upload idle for [upload_resume_ttl] goes, committed or not. *)
let sweep t =
  let now = Unix.gettimeofday () in
  let touched p = try (Unix.stat p).st_mtime with Unix.Unix_error _ -> 0. in
  Array.iter
    (fun f ->
      let id =
        Option.value ~default:f (Filename.chop_suffix_opt ~suffix:".json" f)
      in
      let busy = Mutex.protect t.lock (fun () -> Hashtbl.mem t.receiving id) in
      if
        (not busy)
        && now -. Float.max (touched (spool t id)) (touched (record_path t id))
           > upload_resume_ttl
      then remove t id)
    (try Sys.readdir t.dir with Sys_error _ -> [||])
