(* Public share serving for the http-proxy frontend.

   Share links are public URLs: these routes carry no HMAC and are guarded only
   by the unguessable token plus the shares-prefix confinement in {!load}. They
   are deliberately kept off the signed object API.

   Content is served through {!File} instantiated over {!Layout.Identity}, so a
   share manifest's backend key is used directly as a file key and reads
   demand-page through the ordinary local cache: an HTTP range fetches only the
   chunks it covers, and nothing is ever assembled into the store. Cold data is
   reclaimed by the existing cache cap like any other cached file. *)

open Lwt.Syntax

type share = {
  typ : string;  (** "file" | "dir" *)
  filename : string;
  key : string;  (** file shares: the file's backend manifest key *)
  dir_prefix : string;  (** dir shares: the folder's namespace prefix *)
}

type child = {
  name : string;
  key : string;  (** subdirectory: its namespace prefix; file: manifest key *)
  is_dir : bool;
  size : int64;
  mtime : float;
}

(* The member currently being streamed into a zip. *)
type streaming = { s_key : string; mutable s_pos : int64; s_size : int64 }

exception Error of Cohttp.Code.status_code * string

let fail status msg = raise (Error (status, msg))

let str name j =
  match Yojson.Safe.Util.member name j with `String s -> s | _ -> ""

let block_size = 256 * 1024

(* ── Content types ───────────────────────────────────────────────────────── *)

(* Extension -> MIME type, embedded from the file the share Lambda loads at
   runtime, so the table has exactly one definition. Same for the browser UI
   below: both deployments serve the same page. *)
let mime_json = [%blob "../../../lambda/mime.json"]
let browse_html = [%blob "../../../lambda/browse.html"]

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

(* ext -> preview kind, injected into browse.html so the page carries no second
   copy of the extension list. *)
let preview_kinds_json =
  `Assoc (List.map (fun (e, m) -> (e, `String (preview_kind m))) mime_table)

module Make (C : Conf.S) = struct
  module Sq = Sync_queue.Make (C)

  (* Never started: shares only ever read. *)
  module F = File.Make_with_layout (C) (Sq) (Layout.Identity)

  let primary () =
    match C.backends with
      | b :: _ -> b
      | [] -> failwith "no backends configured"

  (* ── Share manifest ────────────────────────────────────────────────────── *)

  let is_hex s =
    s <> ""
    && String.for_all
         (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
         s

  (* The token is the manifest's random id and the key is rebuilt under our own
     prefix, so a hex-only token cannot address anything outside it. *)
  let load token =
    if not (is_hex token) then fail `Bad_request "bad token";
    let (module B : Backend.S) = primary () in
    let* body = B.get_opt ~key:(C.shares_prefix ^ token) () in
    match body with
      | None -> fail `Not_found "not found"
      | Some body ->
          let j =
            try Yojson.Safe.from_string body
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
              key = str "key" j;
              dir_prefix = str "dirPrefix" j;
            }

  (* ── Inode navigation ──────────────────────────────────────────────────── *)

  (* Direct children of a folder namespace. Names live in the object bodies, so
     this reads each child.
     ponytail: one GET per child — fine for ordinary folders; a folder with
     thousands of direct children pays that many round trips. *)
  let children ns =
    let (module B : Backend.S) = primary () in
    (* <...>/manifests/<id>/ -> <...>/manifests/ *)
    let base =
      match String.rindex_opt (String.sub ns 0 (String.length ns - 1)) '/' with
        | Some i -> String.sub ns 0 (i + 1)
        | None -> ns
    in
    let* entries = B.list_all ~prefix:ns () in
    Lwt_list.filter_map_s
      (fun (e : Backend.file_entry) ->
        if e.Backend.key = ns then Lwt.return_none
        else
          let* body = B.get_opt ~key:e.Backend.key () in
          match body with
            | None -> Lwt.return_none
            | Some body -> (
                match Folder.marker_of_string body with
                  | Some m ->
                      Lwt.return_some
                        {
                          name = m.Folder.name;
                          key = base ^ m.Folder.id ^ "/";
                          is_dir = true;
                          size = 0L;
                          mtime = 0.;
                        }
                  | None -> (
                      match Manifest.of_string body with
                        | `Clean m ->
                            Lwt.return_some
                              {
                                name = m.Manifest.name;
                                key = e.Backend.key;
                                is_dir = false;
                                size = m.Manifest.size;
                                mtime = m.Manifest.mtime;
                              }
                        | `Dirty -> Lwt.return_none
                        | exception _ -> Lwt.return_none)))
      entries

  (* A browse-supplied path, rejected if it could escape the shared folder. *)
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

  (* ── Streaming ─────────────────────────────────────────────────────────── *)

  (* Read [len] bytes from [offset] as a stream, demand-paging each block: only
     the chunks a block covers are fetched. *)
  let byte_stream key ~offset ~len =
    let pos = ref offset and left = ref len in
    let started = ref false in
    Lwt_stream.from (fun () ->
        if Int64.compare !left 0L <= 0 then Lwt.return_none
        else
          let* () =
            if !started then Lwt.return_unit
            else (
              started := true;
              F.prepare_read key)
          in
          let n = Int64.to_int (min (Int64.of_int block_size) !left) in
          let* () = F.ensure_readable key ~offset:!pos ~len:n in
          let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout n in
          let* got = F.read key buf ~offset:!pos in
          if got <= 0 then Lwt.return_none
          else (
            pos := Int64.add !pos (Int64.of_int got);
            left := Int64.sub !left (Int64.of_int got);
            Lwt.return_some (String.init got (Bigarray.Array1.get buf))))

  (* Flatten a shared folder into zip members, depth first. Directories are
     emitted too so empty ones survive the round trip. *)
  let walk ns root =
    (* Accumulate reversed and flip once: appending per entry would be quadratic
       in the file count. *)
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

  (* Stream a zip over the flattened members: one block in memory at a time, so
     archive size is bounded only by the ZIP64 format. *)
  let zip_stream members =
    let z = Zip_stream.create () in
    let queue = ref members in
    let cur = ref None in
    let done_ = ref false in
    Lwt_stream.from (fun () ->
        match !cur with
          | Some m when Int64.compare m.s_pos m.s_size < 0 ->
              let n =
                Int64.to_int
                  (min (Int64.of_int block_size) (Int64.sub m.s_size m.s_pos))
              in
              let* () = F.ensure_readable m.s_key ~offset:m.s_pos ~len:n in
              let buf =
                Bigarray.Array1.create Bigarray.char Bigarray.c_layout n
              in
              let* got = F.read m.s_key buf ~offset:m.s_pos in
              if got <= 0 then (
                (* Truncated relative to its manifest; close the member here. *)
                m.s_pos <- m.s_size;
                Lwt.return_some "")
              else (
                let s = String.init got (Bigarray.Array1.get buf) in
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
                | `File (path, c) :: rest ->
                    queue := rest;
                    let* () = F.prepare_read c.key in
                    cur := Some { s_key = c.key; s_pos = 0L; s_size = c.size };
                    Lwt.return_some
                      (Zip_stream.start_entry z ~name:path ~mtime:c.mtime ())))

  (* ── Responses ─────────────────────────────────────────────────────────── *)

  let text ?(status = `OK) body =
    Cohttp_lwt_unix.Server.respond_string ~status
      ~headers:(Cohttp.Header.of_list [("content-type", "text/plain")])
      ~body ()

  let json obj =
    Cohttp_lwt_unix.Server.respond_string ~status:`OK
      ~headers:(Cohttp.Header.of_list [("content-type", "application/json")])
      ~body:(Yojson.Safe.to_string obj)
      ()

  (* RFC 5987 so non-ASCII names survive; the bare [filename] is a fallback for
     clients that ignore [filename*]. *)
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

  let serve_bytes ~key ~size ~name ~inline ~range =
    let* () = F.prepare_read key in
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
            ~body:(Cohttp_lwt.Body.of_stream (byte_stream key ~offset:a ~len))
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
              (Cohttp_lwt.Body.of_stream (byte_stream key ~offset:0L ~len:size))
            ()

  (* The file share's own manifest: its real name and size. *)
  let file_target (share : share) =
    let* m = F.resolved_manifest share.key in
    match m with
      | Some (`Clean m) when m.Manifest.symlink = None ->
          Lwt.return (m.Manifest.name, m.Manifest.size)
      | Some (`Clean _) -> fail `Bad_request "cannot serve a symlink directly"
      | Some `Dirty -> fail `Conflict "upload in progress, try again shortly"
      | None -> fail `Not_found "file not found"

  let download (share : share) ~range =
    if share.typ = "file" then
      let* name, size = file_target share in
      serve_bytes ~key:share.key ~size ~name ~inline:false ~range
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
      | Some (`File c) ->
          if want_json then
            (* browse.html previews media from this URL; it points back here so
               the bytes still stream through the cache. *)
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
            serve_bytes ~key:c.key ~size:c.size ~name:c.name
              ~inline:(not as_download) ~range
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
      replace h "__OG_TITLE__" (escape title) |> fun h ->
      replace h "__OG_DESC__" (escape "Shared folder · tsync") |> fun h ->
      replace h "__SHARE_DATA__" data
    in
    Cohttp_lwt_unix.Server.respond_string ~status:`OK
      ~headers:
        (Cohttp.Header.of_list [("content-type", "text/html; charset=utf-8")])
      ~body:html ()

  (* ── Entry point ───────────────────────────────────────────────────────── *)

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
                ~as_download:(query "dl" = Some "1")
                ~want_json:(query "json" = Some "1")
                ~range
          | _ -> fail `Not_found "not found")
      (function
        | Error (status, msg) -> text ~status (msg ^ "\n")
        | exn ->
            Log.err "share: %s" (Printexc.to_string exn);
            text ~status:`Internal_server_error "internal error\n")
end
