open Tsync_core
open Tsync_store
open Tsync_remote
open Tsync_http

type t = {
  domain : Domain_name.t;
  store : Store.t;
  find :
    Folder_id.t ->
    string list ->
    [ `File of Manifest.t | `Folder of Folder_id.t | `Missing ];
  children : Folder_id.t -> Tree.entry list;
  anchor : Folder_id.t -> Folder.anchor option;
}

let of_context (module C : Context.S) =
  let module T = Tree.Make (C) in
  {
    domain = C.domain;
    store = C.store;
    find = T.find;
    children = (fun id -> T.children ~on_unusable:(Skip ignore) id);
    anchor = T.anchor;
  }

type share = {
  target : [ `File of Key.t | `Dir of Folder_id.t ];
  filename : string;
}

exception Refused of Server.response

let refuse status msg = raise (Refused (Server.text status msg))

let parse_manifest body =
  match Yojson.Safe.from_string body with
    | `Assoc f -> Some f
    | _ | (exception Yojson.Json_error _) -> None

let manifest_domain body =
  Option.bind (parse_manifest body) (fun f ->
      match List.assoc_opt "domain" f with
        | Some (`String d) -> Result.to_option (Domain_name.of_string d)
        | _ -> None)

(* 02 §2.14, security §6.3: an invalid manifest is 502, another domain's is
   absent. *)
let load t token =
  let key =
    match Key.share token with Some k -> k | None -> refuse 400 "bad token"
  in
  let body =
    match t.store.get_opt key with
      | Some b -> Bigstring.to_string b
      | None -> refuse 404 "not found"
  in
  let f =
    match parse_manifest body with
      | Some f -> f
      | None -> refuse 502 "corrupt share manifest"
  in
  let str k =
    match List.assoc_opt k f with Some (`String s) -> Some s | _ -> None
  in
  if List.assoc_opt "v" f <> Some (`Int 1) then
    refuse 502 "corrupt share manifest";
  let domain =
    match Option.map Domain_name.of_string (str "domain") with
      | Some (Ok d) -> d
      | _ -> refuse 502 "corrupt share manifest"
  in
  if not (Domain_name.equal domain t.domain) then refuse 404 "not found";
  let expires =
    match List.assoc_opt "expires" f with
      | Some (`Int n) -> float_of_int n
      | Some (`Float x) -> x
      | _ -> refuse 410 "link expired"
  in
  if expires < Unix.gettimeofday () then refuse 410 "link expired";
  let target =
    match str "type" with
      | Some "file" -> (
          match Option.bind (str "key") Key.of_string with
            | Some k
              when Key.under (Key.manifests domain) k
                   && Key.folder_of_namespace_key domain k <> None ->
                `File k
            | _ -> refuse 502 "corrupt share manifest")
      | Some "dir" -> (
          match Option.bind (str "folderId") Folder_id.of_string with
            | Some id -> `Dir id
            | None -> refuse 502 "corrupt share manifest")
      | _ -> refuse 502 "unknown share type"
  in
  { target; filename = Option.value ~default:"share" (str "filename") }

let claims t token =
  match load t token with _ -> true | exception Refused _ -> false

let mime_table =
  match Yojson.Safe.from_string Share_assets.mime with
    | `Assoc l ->
        List.filter_map (function k, `String v -> Some (k, v) | _ -> None) l
    | _ -> []

let extension name =
  match String.rindex_opt name '.' with
    | Some i ->
        String.lowercase_ascii
          (String.sub name (i + 1) (String.length name - i - 1))
    | None -> ""

let mime name = List.assoc_opt (extension name) mime_table

let preview_kind m =
  if String.starts_with ~prefix:"image/" m then Some "image"
  else if String.starts_with ~prefix:"audio/" m then Some "audio"
  else if String.starts_with ~prefix:"video/" m then Some "video"
  else if m = "application/pdf" then Some "pdf"
  else if String.starts_with ~prefix:"text/html" m then Some "html"
  else if String.starts_with ~prefix:"text/" m || m = "application/json" then
    Some "text"
  else None

let html_escape s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '&' -> Buffer.add_string b "&amp;"
      | '<' -> Buffer.add_string b "&lt;"
      | '>' -> Buffer.add_string b "&gt;"
      | '"' -> Buffer.add_string b "&quot;"
      | '\'' -> Buffer.add_string b "&#39;"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

(* security §13: JSON inside a script element cannot close it. *)
let script_json j =
  List.fold_left
    (fun s (sub, by) -> Text.replace_all ~sub ~by s)
    (Yojson.Safe.to_string j)
    [
      ("<", "\\u003c");
      (">", "\\u003e");
      ("&", "\\u0026");
      ("\xe2\x80\xa8", "\\u2028");
      ("\xe2\x80\xa9", "\\u2029");
    ]

(* Single pass: a substituted value is never scanned again. *)
let fill template values =
  let b = Buffer.create (String.length template) in
  let n = String.length template in
  let rec go i =
    if i < n then (
      match
        List.find_opt
          (fun (k, _) ->
            i + String.length k <= n
            && String.sub template i (String.length k) = k)
          values
      with
        | Some (k, v) ->
            Buffer.add_string b v;
            go (i + String.length k)
        | None ->
            Buffer.add_char b template.[i];
            go (i + 1))
  in
  go 0;
  Buffer.contents b

let stem name =
  match String.rindex_opt name '.' with
    | Some i when i > 0 -> String.sub name 0 i
    | _ -> name

let html_headers =
  [
    ("content-type", "text/html; charset=utf-8");
    ("x-content-type-options", "nosniff");
    ("referrer-policy", "no-referrer");
  ]

let browse_page ~token share =
  let title = stem share.filename in
  let kinds =
    List.sort_uniq compare
      (List.filter_map
         (fun (ext, m) ->
           Option.map (fun k -> (ext, `String k)) (preview_kind m))
         mime_table)
  in
  let page =
    fill Share_assets.browse
      [
        ("__PREVIEW_KINDS__", script_json (`Assoc kinds));
        ("__PLAYER_JS__", Share_assets.player);
        ("__OG_TITLE__", html_escape title);
        ("__OG_DESC__", html_escape "Shared folder · tsync");
        ( "__SHARE_DATA__",
          script_json
            (`Assoc
               [("base", `String ("/s/" ^ token)); ("title", `String title)]) );
      ]
  in
  { Server.status = 200; headers = html_headers; body = String page }

(* security §13: an ASCII fallback plus the RFC 5987 form. *)
let disposition kind name =
  let ascii =
    String.map
      (fun c ->
        if Char.code c < 32 || Char.code c > 126 || c = '"' || c = '\\' then '_'
        else c)
      name
  in
  let pct =
    String.concat ""
      (List.map
         (fun c ->
           match c with
             | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' ->
                 String.make 1 c
             | c -> Printf.sprintf "%%%02X" (Char.code c))
         (List.of_seq (String.to_seq name)))
  in
  Printf.sprintf "%s; filename=\"%s\"; filename*=UTF-8''%s" kind ascii pct

(* §A9.5: one range, [bytes=a-b], [a-] or [-n]. *)
let parse_range size header =
  let digits s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s in
  match header with
    | Some h when String.starts_with ~prefix:"bytes=" h -> (
        match
          String.split_on_char '-' (String.sub h 6 (String.length h - 6))
        with
          | [a; b] when digits a && digits b ->
              let a = int_of_string a and b = int_of_string b in
              if a > b then `Whole
              else if a >= size then `Unsatisfiable
              else `Range (a, min b (size - 1))
          | [a; ""] when digits a ->
              let a = int_of_string a in
              if a >= size then `Unsatisfiable else `Range (a, size - 1)
          | [""; n] when digits n ->
              let n = int_of_string n in
              if n = 0 then `Whole
              else if size = 0 then `Unsatisfiable
              else `Range (max 0 (size - n), size - 1)
          | _ -> `Whole)
    | _ -> `Whole

(* §A9.4: only the chunks the range covers, each checked against its key; a
   chunk missing or failing it aborts the response, which the client then
   sees incomplete. *)
let stream t (m : Manifest.t) ~off ~len feed =
  let stop = off + len in
  let rec go i =
    if i < m.count then (
      let start = i * m.chunk_size in
      let clen = Chunking.length ~size:m.size ~cs:m.chunk_size i in
      if start < stop && start + clen > off then (
        let ck = Manifest.key m i in
        match t.store.get_opt (Key.chunk t.domain ck) with
          | Some b when Bigstring.length b = clen && Chunk_key.names ck b ->
              let lo = max off start - start
              and hi = min stop (start + clen) - start in
              feed (Bigstring.sub b ~off:lo ~len:(hi - lo));
              go (i + 1)
          | _ ->
              Fail.corrupt
                "share: chunk %s is missing or does not match its key"
                (Chunk_key.to_string ck))
      else if start < stop then go (i + 1))
  in
  go 0

let file_response t (r : Server.request) ~name ~inline (m : Manifest.t) =
  if m.link <> None then refuse 400 "cannot serve a symlink directly";
  let size = m.size in
  let base =
    [
      ( "content-type",
        Option.value ~default:"application/octet-stream" (mime name) );
      ( "content-disposition",
        disposition (if inline then "inline" else "attachment") name );
      ("accept-ranges", "bytes");
      ("content-security-policy", "sandbox");
      ("x-content-type-options", "nosniff");
      ("referrer-policy", "no-referrer");
    ]
  in
  let body off len =
    if len = 0 then Server.Empty else Server.stream (stream t m ~off ~len)
  in
  match parse_range size (Codec.header r.headers "range") with
    | `Unsatisfiable ->
        {
          Server.status = 416;
          headers = [("content-range", Printf.sprintf "bytes */%d" size)];
          body = Empty;
        }
    | `Range (a, b) ->
        {
          Server.status = 206;
          headers =
            base @ [("content-range", Printf.sprintf "bytes %d-%d/%d" a b size)];
          body = body a (b - a + 1);
        }
    | `Whole -> { Server.status = 200; headers = base; body = body 0 size }

let manifest_at t key =
  match t.store.get_opt key with
    | Some b -> (
        match Manifest.of_body b with
          | Some m -> m
          | None -> refuse 404 "not found")
    | None -> refuse 404 "not found"

(* security §6.3: a shared folder in the trash is not served. *)
let live_folder t id =
  if not (Folder_id.is_root id) then (
    match t.anchor id with
      | Some a when Folder_id.equal a.parent Folder_id.trash ->
          refuse 404 "not found"
      | _ -> ())

let path_parts path =
  let parts = List.filter (( <> ) "") (String.split_on_char '/' path) in
  if List.exists (fun p -> p = "." || p = "..") parts then refuse 400 "bad path";
  parts

let listing t id =
  let dirs, files =
    List.partition_map
      (fun (e : Tree.entry) ->
        match e.body with
          | Dir m -> Left m.name
          | File m -> Right (m.name, m.size))
      (t.children id)
  in
  let by_lower a b =
    compare (String.lowercase_ascii a) (String.lowercase_ascii b)
  in
  `Assoc
    [
      ("dirs", `List (List.map (fun d -> `String d) (List.sort by_lower dirs)));
      ( "files",
        `List
          (List.map
             (fun (n, s) -> `Assoc [("name", `String n); ("size", `Int s)])
             (List.sort (fun (a, _) (b, _) -> by_lower a b) files)) );
    ]

let json j =
  {
    Server.status = 200;
    headers =
      [
        ("content-type", "application/json");
        ("x-content-type-options", "nosniff");
      ];
    body = String (Yojson.Safe.to_string j);
  }

let pct_path path =
  String.concat ""
    (List.map
       (fun c ->
         match c with
           | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' | '/'
             ->
               String.make 1 c
           | c -> Printf.sprintf "%%%02X" (Char.code c))
       (List.of_seq (String.to_seq path)))

let entry_name (e : Tree.entry) =
  match e.body with Dir m -> m.Folder.name | File m -> m.Manifest.name

(* §A9.7: members are computed before the response starts, depth first,
   children bytewise by name. *)
let zip_response t ~max_members id filename =
  let root = stem filename in
  let rec walk prefix id acc =
    List.fold_left
      (fun acc (e : Tree.entry) ->
        if List.length acc > max_members then refuse 413 "too many members";
        match e.body with
          | Dir m ->
              let p = prefix ^ "/" ^ m.name in
              walk p m.id (`Dir p :: acc)
          | File m -> `File (prefix ^ "/" ^ m.name, e.key) :: acc)
      acc
      (List.sort
         (fun a b -> compare (entry_name a) (entry_name b))
         (t.children id))
  in
  let members = List.rev (walk root id [`Dir root]) in
  {
    Server.status = 200;
    headers =
      [
        ("content-type", "application/zip");
        ("content-disposition", disposition "attachment" filename);
        ("x-content-type-options", "nosniff");
        ("referrer-policy", "no-referrer");
      ];
    body =
      Server.stream (fun write ->
          let z = Zip.create write in
          List.iter
            (function
              | `Dir name -> Zip.add_dir z ~name ~mtime:0.
              | `File (name, key) -> (
                  match Option.bind (t.store.get_opt key) Manifest.of_body with
                    | Some m when m.link = None ->
                        Zip.add_file z ~name ~mtime:m.mtime (fun feed ->
                            stream t m ~off:0 ~len:m.size feed)
                    | _ -> Log.info "share: %s vanished since the walk" name))
            members;
          Zip.finish z);
  }

let handle t ~max_zip_members (r : Server.request) ~token ~sub params =
  try
    let share = load t token in
    let param k = List.assoc_opt k params in
    match (share.target, sub) with
      | `File key, ("" | "download") ->
          file_response t r ~name:share.filename ~inline:false
            (manifest_at t key)
      | `Dir id, "" ->
          live_folder t id;
          browse_page ~token share
      | `Dir id, "download" ->
          live_folder t id;
          zip_response t ~max_members:max_zip_members id share.filename
      | `Dir id, "list" -> (
          live_folder t id;
          match
            t.find id (path_parts (Option.value ~default:"" (param "path")))
          with
            | `Folder f -> json (listing t f)
            | _ -> refuse 404 "not found")
      | `Dir id, "f" -> (
          live_folder t id;
          let parts = path_parts (Option.value ~default:"" (param "path")) in
          if parts = [] then refuse 400 "bad path";
          match t.find id parts with
            | `File m ->
                let name = List.nth parts (List.length parts - 1) in
                if param "json" = Some "1" then
                  json
                    (`Assoc
                       [
                         ( "url",
                           `String
                             ("/s/" ^ token ^ "/f?path="
                             ^ pct_path (String.concat "/" parts)) );
                         ("name", `String name);
                         ( "contentType",
                           match mime name with
                             | Some m -> `String m
                             | None -> `Null );
                         ("size", `Int m.size);
                       ])
                else file_response t r ~name ~inline:(param "dl" <> Some "1") m
            | _ -> refuse 404 "not found")
      | _ -> refuse 404 "not found"
  with
    | Refused response -> response
    | Fail.E f ->
        Log.err "share: %s" f.reason;
        Server.text 500 "internal error"
