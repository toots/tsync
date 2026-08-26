(* Public share serving for the http-proxy frontend. These routes carry no HMAC
   and are guarded only by the unguessable token plus the shares-prefix
   confinement in {!load}, so they are kept off the signed object API.

   Content comes from {!Data} straight out of the domain's chunk cache: a range
   fetches only the chunks it covers, nothing is assembled, and nothing is
   written into the local manifest mirror. *)

open Lwt.Syntax

type share = {
  typ : string;  (** "file" | "dir" *)
  filename : string;
  key : Stored_key.t;  (** file shares: the file's backend manifest key *)
  dir_prefix : Stored_key.t;  (** dir shares: the folder's namespace prefix *)
}

type child = {
  name : string;
  key : Stored_key.t;
      (** subdirectory: its namespace prefix; file: manifest key *)
  is_dir : bool;
  size : int64;
  mtime : float;
}

(* The member currently being streamed into a zip. *)
type streaming = {
  s_key : Stored_key.t;
  s_manifest : Manifest.t;
  mutable s_pos : int64;
  s_size : int64;
}

exception Error of Cohttp.Code.status_code * string

let fail status msg = raise (Error (status, msg))

let str name j =
  match Yojson.Safe.Util.member name j with `String s -> s | _ -> ""

let block_size = 256 * 1024

(* Counted here rather than by the frontend: a share body streams, so the bytes
   leave long after the handler returned. *)
let served_bytes = Metrics.counter ()

(* Share routes carry no credential, so how many run at once is chosen by the
   public rather than by a client we configured. Each pull allocates a
   [block_size] buffer, so bounding the pull is what bounds bytes held here.

   Its own pool, not the signed API's: a burst of downloads must not starve a
   replica's writes. Module level, so the bound is the process rather than one
   domain. *)
let read_slots_max = 16

(* No [max_waiting]: a refusal here would raise once the response's status and
   content-length are already on the wire, which a client reads as a corrupt
   file rather than as backpressure. Waiting is the only answer this layer can
   give honestly.

   ponytail: the queue is then bounded only by how many responses are open at
   once, which nothing caps — bound admission in [callback] if a proxy is ever
   exposed to a load that reaches it. *)
let read_slots =
  Io_lwt.Bounded.create ~name:"share reads" ~max:read_slots_max ()

(* Embedded from the files the share Lambda loads at runtime, so the table and
   the browser UI have one definition across both deployments. *)
let mime_json = [%blob "../../../lambda/mime.json"]
let browse_html = [%blob "../../../lambda/browse.html"]
let player_js = [%blob "../../../lambda/player.js"]

let mime_table =
  match Yojson.Safe.from_string mime_json with
    | `Assoc l ->
        List.filter_map
          (function ext, `String m -> Some (ext, m) | _ -> None)
          l
    | _ | (exception _) -> failwith "share: malformed mime.json"

let extension name =
  match String.rindex_opt name '.' with
    | None -> ""
    | Some i ->
        String.lowercase_ascii
          (String.sub name (i + 1) (String.length name - i - 1))

let mime_type name = List.assoc_opt (extension name) mime_table

(* How browse.html previews a file of this type. *)
let preview_kind mime =
  let base = List.hd (String.split_on_char ';' mime) in
  let starts p = String.starts_with ~prefix:p base in
  if starts "image/" then "image"
  else if starts "audio/" then "audio"
  else if starts "video/" then "video"
  else if base = "application/pdf" then "pdf"
  else if base = "text/html" then "html"
  else "text"

(* Injected into browse.html so the page carries no second copy of the extension
   list. *)
let preview_kinds_json =
  `Assoc (List.map (fun (e, m) -> (e, `String (preview_kind m))) mime_table)

module Make (C : Conf_lwt.S) = struct
  module Lk = Logical_key.Make (C)
  module R = Remote.Make_with_layout (C) (Layout_lwt.Identity)
  module D = Data_lwt.Make (C) (R)

  (* Share manifests come from the backend, never the local mirror: their keys
     are inode-space, so mirroring them would plant phantom entries in the
     domain's listings.

     ponytail: manifests are memoized unbounded-but-cleared, a share of a 30k
     chunk file being a 2.5MB body not worth re-GETting per range request. Swap
     in an LRU if one proxy ever fronts enough distinct shares to matter. *)
  let manifests : (string, Manifest.t) Hashtbl.t = Hashtbl.create 32
  let max_memoized_manifests = 256

  let manifest_of key =
    let key = Stored_key.to_string key in
    match Hashtbl.find_opt manifests key with
      | Some m -> Lwt.return_some m
      | None -> (
          (* Identity layout: the logical key's spelling is the backend key. *)
          let* state =
            match Option.map Lk.file (Lk.rel_of_string key) with
              | Some k -> R.fetch_manifest ~key:k ()
              | None -> Lwt.return_none
          in
          match state with
            | Some m ->
                if Hashtbl.length manifests >= max_memoized_manifests then
                  Hashtbl.reset manifests;
                Hashtbl.replace manifests key m;
                Lwt.return_some m
            | None -> Lwt.return_none)

  module Tree = Inode_tree.Make (C)
  module B = (val C.store : C.Store)

  let is_hex s =
    s <> ""
    && String.for_all
         (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
         s

  let load token =
    if not (is_hex token) then fail `Bad_request "bad token";
    let* body =
      B.get_opt ~key:(Stored_key.share_key ~prefix:C.shares_prefix token) ()
    in
    match body with
      | None -> fail `Not_found "not found"
      | Some body ->
          let j =
            try Yojson.Safe.from_string (Bigstring.to_string body)
            with _ -> fail `Bad_gateway "corrupt share manifest"
          in
          let expires =
            match Yojson.Safe.Util.member "expires" j with
              | `Int i -> float_of_int i
              | `Float f -> f
              | _ -> 0.
          in
          if Unix.time () > expires then fail `Gone "link expired";
          Lwt.return
            {
              typ = str "type" j;
              filename = str "filename" j;
              key = Stored_key.listed (str "key" j);
              dir_prefix = Stored_key.listed (str "dirPrefix" j);
            }

  (* A subdirectory's [key] is its own namespace, so [resolve] descends by
     handing it straight back. *)
  let children ns =
    let folder_id = Stored_key.folder_id_of ns in
    let+ entries =
      Tree.children ~on_unusable:(`Skip (fun _ _ -> ())) ~folder_id ()
    in
    List.map
      (fun (e : Inode_tree.entry) ->
        match e.Inode_tree.body with
          | Inode_tree.Dir m ->
              {
                name = m.Folder.name;
                key = Tree.namespace_prefix m.Folder.id;
                is_dir = true;
                size = 0L;
                mtime = 0.;
              }
          | Inode_tree.File m ->
              {
                (* Fetched by backend key ([<folder-id>/<hash>]), so the
                   location cannot name it and the body must. *)
                name = Manifest.recorded_name m;
                key = e.Inode_tree.bkey;
                is_dir = false;
                size = Manifest.size m;
                mtime = Manifest.mtime m;
              })
      entries

  (* Rejects a browse-supplied path that could escape the shared folder. *)
  let safe_parts path =
    let parts =
      List.filter
        (fun p -> p <> "")
        (String.split_on_char '/' (Option.value ~default:"" path))
    in
    if List.exists (fun p -> p = "." || p = "..") parts then
      fail `Bad_request "bad path";
    parts

  let resolve ns parts =
    let rec go loc = function
      | [] -> Lwt.return_some (`Dir loc)
      | part :: rest -> (
          let* cs = children loc in
          match List.find_opt (fun c -> c.name = part) cs with
            | None -> Lwt.return_none
            | Some c when c.is_dir -> go c.key rest
            | Some c ->
                if rest = [] then Lwt.return_some (`File c) else Lwt.return_none
          )
    in
    go ns parts

  (* Headers are already on the wire when a body stream runs, so a failure here
     only truncates the response and cohttp logs nothing of ours. *)
  let logged what f =
    Lwt.catch f (fun exn ->
        Log.err "share: %s stream failed: %s" what (Printexc.to_string exn);
        Lwt.fail exn)

  (* One block at a time: each fetches only the chunks it covers. *)
  let byte_stream ~manifest key ~offset ~len =
    let id = Stored_key.to_string key in
    let pos = ref offset and left = ref len in
    Lwt_stream.from (fun () ->
        logged id @@ fun () ->
        if Int64.compare !left 0L <= 0 then Lwt.return_none
        else
          (* Slot before the buffer, not after. *)
          Io_lwt.Bounded.use read_slots @@ fun () ->
          let n = Int64.to_int (min (Int64.of_int block_size) !left) in
          let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout n in
          let* got = D.pread ~id ~manifest buf ~offset:!pos in
          if got <= 0 then Lwt.return_none
          else (
            Metrics.count served_bytes got;
            pos := Int64.add !pos (Int64.of_int got);
            left := Int64.sub !left (Int64.of_int got);
            Lwt.return_some (Bigstringaf.substring buf ~off:0 ~len:got)))

  (* Depth first. Directories are emitted too, so empty ones survive the round
     trip. *)
  let walk ns root =
    (* Reversed then flipped once: appending per entry is quadratic. *)
    let rec go acc ns prefix =
      let* cs = children ns in
      let cs = List.sort (fun a b -> compare a.name b.name) cs in
      Lwt_list.fold_left_s
        (fun acc c ->
          let path = if prefix = "" then c.name else prefix ^ "/" ^ c.name in
          if c.is_dir then go (`Dir path :: acc) c.key path
          else Lwt.return (`File (path, c) :: acc))
        acc cs
    in
    let+ rev = go [] ns root in
    List.rev rev

  (* One block in memory at a time, so archive size is bounded only by ZIP64. *)
  let zip_stream members =
    let z = Zip_stream.create () in
    let queue = ref members in
    let cur = ref None in
    let done_ = ref false in
    Lwt_stream.from (fun () ->
        logged "zip" @@ fun () ->
        match !cur with
          | Some m when Int64.compare m.s_pos m.s_size < 0 ->
              (* Slot before the buffer, not after. *)
              Io_lwt.Bounded.use read_slots @@ fun () ->
              let n =
                Int64.to_int
                  (min (Int64.of_int block_size) (Int64.sub m.s_size m.s_pos))
              in
              let buf =
                Bigarray.Array1.create Bigarray.char Bigarray.c_layout n
              in
              let* got =
                D.pread
                  ~id:(Stored_key.to_string m.s_key)
                  ~manifest:m.s_manifest buf ~offset:m.s_pos
              in
              if got <= 0 then (
                (* Truncated relative to its manifest; close the member here. *)
                m.s_pos <- m.s_size;
                Lwt.return_some "")
              else (
                Metrics.count served_bytes got;
                let s = Bigstringaf.substring buf ~off:0 ~len:got in
                m.s_pos <- Int64.add m.s_pos (Int64.of_int got);
                Zip_stream.feed z s;
                Lwt.return_some s)
          | Some _ ->
              cur := None;
              Lwt.return_some (Zip_stream.end_entry z)
          | None -> (
              match !queue with
                | [] ->
                    if !done_ then Lwt.return_none
                    else (
                      done_ := true;
                      Lwt.return_some (Zip_stream.finish z))
                | `Dir path :: rest ->
                    queue := rest;
                    Lwt.return_some
                      (Zip_stream.add_directory z ~name:path ~mtime:0.)
                | `File (path, c) :: rest -> (
                    queue := rest;
                    let* manifest = manifest_of c.key in
                    match manifest with
                      | None ->
                          (* Vanished or replaced mid-archive: skip the member
                             rather than abort the download. *)
                          Log.err "share: no manifest for %s"
                            (Stored_key.to_string c.key);
                          Lwt.return_some ""
                      | Some manifest ->
                          cur :=
                            Some
                              {
                                s_key = c.key;
                                s_manifest = manifest;
                                s_pos = 0L;
                                s_size = c.size;
                              };
                          Lwt.return_some
                            (Zip_stream.start_entry z ~name:path ~mtime:c.mtime
                               ()))))

  let text ?(status = `OK) body =
    Cohttp_lwt_unix.Server.respond_string ~status
      ~headers:(Cohttp.Header.of_list [("content-type", "text/plain")])
      ~body ()

  let json obj =
    Cohttp_lwt_unix.Server.respond_string ~status:`OK
      ~headers:(Cohttp.Header.of_list [("content-type", "application/json")])
      ~body:(Yojson.Safe.to_string obj)
      ()

  (* RFC 5987 for non-ASCII names; bare [filename] is the fallback for clients
     ignoring [filename*]. *)
  let disposition ~inline name =
    let ascii =
      String.map
        (fun c ->
          if Char.code c < 32 || Char.code c > 126 || c = '"' then '_' else c)
        name
    in
    Printf.sprintf "%s; filename=\"%s\"; filename*=UTF-8''%s"
      (if inline then "inline" else "attachment")
      ascii
      (Uri.pct_encode ~component:`Path name)

  (* [bytes=a-b] / [bytes=a-] / [bytes=-n] against a known [size]. *)
  let parse_range header size =
    match header with
      | None -> None
      | Some h when not (String.starts_with ~prefix:"bytes=" h) -> None
      | Some h -> (
          let spec = String.sub h 6 (String.length h - 6) in
          match String.split_on_char '-' spec with
            | [first; last] -> (
                let i64 s = Int64.of_string_opt (String.trim s) in
                match (i64 first, i64 last) with
                  | Some a, Some b when Int64.compare a b <= 0 ->
                      Some (a, min b (Int64.sub size 1L))
                  | Some a, None -> Some (a, Int64.sub size 1L)
                  | None, Some n when Int64.compare n 0L > 0 ->
                      Some (max 0L (Int64.sub size n), Int64.sub size 1L)
                  | _ -> None)
            | _ -> None)

  let serve_bytes ~manifest ~key ~size ~name ~inline ~range =
    let ctype =
      Option.value (mime_type name) ~default:"application/octet-stream"
    in
    let base =
      [
        ("content-type", ctype);
        ("content-disposition", disposition ~inline name);
        ("accept-ranges", "bytes");
      ]
    in
    match parse_range range size with
      | Some (a, b) when Int64.compare a size < 0 ->
          let len = Int64.add (Int64.sub b a) 1L in
          let headers =
            base
            @ [
                ("content-length", Int64.to_string len);
                ("content-range", Printf.sprintf "bytes %Ld-%Ld/%Ld" a b size);
              ]
          in
          Cohttp_lwt_unix.Server.respond ~status:`Partial_content
            ~headers:(Cohttp.Header.of_list headers)
            ~body:
              (Cohttp_lwt.Body.of_stream
                 (byte_stream ~manifest key ~offset:a ~len))
            ()
      | Some _ ->
          Cohttp_lwt_unix.Server.respond_string
            ~status:`Requested_range_not_satisfiable
            ~headers:
              (Cohttp.Header.of_list
                 [("content-range", Printf.sprintf "bytes */%Ld" size)])
            ~body:"" ()
      | None ->
          let headers = base @ [("content-length", Int64.to_string size)] in
          Cohttp_lwt_unix.Server.respond ~status:`OK
            ~headers:(Cohttp.Header.of_list headers)
            ~body:
              (Cohttp_lwt.Body.of_stream
                 (byte_stream ~manifest key ~offset:0L ~len:size))
            ()

  (* The file share's own manifest: its real name and size. *)
  let file_target (share : share) =
    let* m = manifest_of share.key in
    match m with
      | Some m when Manifest.symlink m = None -> Lwt.return m
      | Some _ -> fail `Bad_request "cannot serve a symlink directly"
      | None -> fail `Not_found "file not found"

  let download (share : share) ~range =
    if share.typ = "file" then
      let* manifest = file_target share in
      serve_bytes ~manifest ~key:share.key ~size:(Manifest.size manifest)
        ~name:(Manifest.recorded_name manifest)
        ~inline:false ~range
    else (
      let root = Filename.remove_extension share.filename in
      let* members = walk share.dir_prefix root in
      (* Length is unknown until the archive is built, so this streams chunked. *)
      Cohttp_lwt_unix.Server.respond ~status:`OK
        ~headers:
          (Cohttp.Header.of_list
             [
               ("content-type", "application/zip");
               ("content-disposition", disposition ~inline:false share.filename);
             ])
        ~body:(Cohttp_lwt.Body.of_stream (zip_stream members))
        ())

  let list_response (share : share) path =
    let* target = resolve share.dir_prefix (safe_parts path) in
    match target with
      | Some (`Dir ns) ->
          let* cs = children ns in
          let by_name a b =
            compare (String.lowercase_ascii a) (String.lowercase_ascii b)
          in
          let dirs =
            List.sort by_name
              (List.filter_map
                 (fun c -> if c.is_dir then Some c.name else None)
                 cs)
          in
          let files =
            List.sort
              (fun a b -> by_name (fst a) (fst b))
              (List.filter_map
                 (fun c -> if c.is_dir then None else Some (c.name, c.size))
                 cs)
          in
          json
            (`Assoc
               [
                 ("dirs", `List (List.map (fun d -> `String d) dirs));
                 ( "files",
                   `List
                     (List.map
                        (fun (n, s) ->
                          `Assoc
                            [
                              ("name", `String n);
                              ("size", `Intlit (Int64.to_string s));
                            ])
                        files) );
               ])
      | _ -> fail `Not_found "not found"

  let serve_child (share : share) ~token ~path ~as_download ~want_json ~range =
    let parts = safe_parts path in
    if parts = [] then fail `Bad_request "not a file";
    let* target = resolve share.dir_prefix parts in
    match target with
      | Some (`File c) -> (
          if want_json then
            (* browse.html previews media from this URL, pointing back here so
               the bytes stream through the cache. *)
            json
              (`Assoc
                 [
                   ( "url",
                     `String
                       (Printf.sprintf "/s/%s/f?path=%s" token
                          (Uri.pct_encode ~component:`Query_value
                             (String.concat "/" parts))) );
                   ("name", `String c.name);
                   ( "contentType",
                     match mime_type c.name with
                       | Some m -> `String m
                       | None -> `Null );
                   ("size", `Intlit (Int64.to_string c.size));
                 ])
          else
            let* manifest = manifest_of c.key in
            match manifest with
              | None -> fail `Not_found "file not found"
              | Some manifest ->
                  serve_bytes ~manifest ~key:c.key ~size:c.size ~name:c.name
                    ~inline:(not as_download) ~range)
      | _ -> fail `Not_found "file not found"

  let browse (share : share) token =
    let title = Filename.remove_extension share.filename in
    let escape s =
      String.concat ""
        (List.map
           (function
             | '&' -> "&amp;"
             | '<' -> "&lt;"
             | '>' -> "&gt;"
             | '"' -> "&quot;"
             | c -> String.make 1 c)
           (List.init (String.length s) (String.get s)))
    in
    let replace hay needle rep =
      let n = String.length needle in
      let b = Buffer.create (String.length hay) in
      let i = ref 0 in
      while !i < String.length hay do
        if !i + n <= String.length hay && String.sub hay !i n = needle then (
          Buffer.add_string b rep;
          i := !i + n)
        else (
          Buffer.add_char b hay.[!i];
          incr i)
      done;
      Buffer.contents b
    in
    let data =
      Yojson.Safe.to_string
        (`Assoc [("base", `String ("/s/" ^ token)); ("title", `String title)])
    in
    let html =
      browse_html |> fun h ->
      replace h "__PREVIEW_KINDS__" (Yojson.Safe.to_string preview_kinds_json)
      |> fun h ->
      replace h "__PLAYER_JS__" player_js |> fun h ->
      replace h "__OG_TITLE__" (escape title) |> fun h ->
      replace h "__OG_DESC__" (escape "Shared folder · tsync") |> fun h ->
      replace h "__SHARE_DATA__" data
    in
    Cohttp_lwt_unix.Server.respond_string ~status:`OK
      ~headers:
        (Cohttp.Header.of_list [("content-type", "text/html; charset=utf-8")])
      ~body:html ()

  let handle ~token ~sub ~query ~range =
    Lwt.catch
      (fun () ->
        let* share = load token in
        let is_dir = share.typ = "dir" in
        match sub with
          | "" when is_dir -> browse share token
          | "" | "download" -> download share ~range
          | "list" when is_dir -> list_response share (query "path")
          | "f" when is_dir ->
              serve_child share ~token ~path:(query "path")
                ~as_download:(Field_spec.bool ~default:false (query "dl"))
                ~want_json:(Field_spec.bool ~default:false (query "json"))
                ~range
          | _ -> fail `Not_found "not found")
      (function
        | Error (status, msg) -> text ~status (msg ^ "\n")
        | exn ->
            Log.err "share: %s" (Printexc.to_string exn);
            text ~status:`Internal_server_error "internal error\n")
end
