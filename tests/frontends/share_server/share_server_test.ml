(* End-to-end snapshot of the http-proxy share server: a token resolves to a
   share manifest, and content — whole files, byte ranges, folder listings,
   per-file fetches, folder zips — is served out of the demand-paged cache
   without any HMAC and without assembling anything into the store.

   The fixture uploads real files into a local backend, then pins folder ids so
   every key in the snapshot is stable. *)

open Lwt.Syntax

let root = "/tmp/tsync-share-server-test"
let store_dir = root ^ "/store"
let cache_dir = root ^ "/cache"
let data_dir = root ^ "/data"

(* 1980-01-01 UTC: fixed so manifest mtimes and zip timestamps never drift. *)
let mtime = 315532800.
let expires = 4102444800 (* 2100-01-01 *)

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = "tsync/testdom/manifests/"
  let chunk_prefix = "tsync/testdom/chunks/"
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = "tsync/testdom/cursor"
  let shares_prefix = "tsync/shares/"

  let store =
    Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some store_dir) ()

  let members = [Backend.member ~name:"local" store]
  let cache_root = cache_dir
  let data_dir = data_dir
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 1
  let max_downloads = 1

  (* Small enough that the fixture spans several chunks, so range reads exercise
     partial fetching rather than pulling one chunk. *)
  let chunk_size = Some 16
  let cache_chunk_size = Some 16
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module R = Remote.Make (C)
module Mf = Manifest.Make (C)
module Sh = Share_server.Make (C)

let backend () = C.store

let write_local path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

(* Upload [content] as the domain-relative path [rel]; returns its backend key. *)
let upload rel content =
  let src = Filename.concat data_dir (Filename.basename rel) in
  write_local src content;
  let key = C.domain_prefix ^ rel in
  let* chunk_size = R.chunk_size () in
  let* _ = R.upload ~key ~src_path:src ~mtime ~chunk_size () in
  let module L = Layout.Inode.Make (C) in
  L.ensure_manifest_key key

let hello_body = "hello world, this spans several chunks\n"
let inner_body = "inner file contents\n"

let build_fixture () =
  (* Pin the subfolder id: [Folder_ids.ensure_id] would mint a random one. *)
  let* () =
    Folder_ids.write ~cache_root:C.cache_root ~domain_name:C.domain_name "sub"
      { Folder.name = "sub"; id = "subid" }
  in
  let* hello_key = upload "hello.txt" hello_body in
  let* _ = upload "sub/inner.txt" inner_body in
  (* The folder marker that makes "sub" visible in a listing. *)
  let (module B : Backend.S) = backend () in
  let* () =
    B.put
      ~key:(C.domain_prefix ^ Folder.child_key ~folder_id:Folder.root_id "sub")
      ~data:
        (Bigstring.of_string
           (Folder.marker_to_string { Folder.name = "sub"; id = "subid" }))
      ()
  in
  (* Share manifests, written the way [tsync share] writes them. *)
  let share token json =
    B.put ~key:(C.shares_prefix ^ token)
      ~data:(Bigstring.of_string (Yojson.Safe.to_string json))
      ()
  in
  let* () =
    share "aa"
      (`Assoc
         [
           ("v", `Int 1);
           ("expires", `Int expires);
           ("type", `String "file");
           ("key", `String hello_key);
           ("chunkPrefix", `String C.chunk_prefix);
           ("filename", `String "hello.txt");
         ])
  in
  let* () =
    share "bb"
      (`Assoc
         [
           ("v", `Int 1);
           ("expires", `Int expires);
           ("type", `String "dir");
           ("chunkPrefix", `String C.chunk_prefix);
           ("dirPrefix", `String (C.domain_prefix ^ Folder.root_id ^ "/"));
           ("filename", `String "testdom.zip");
         ])
  in
  share "cc"
    (`Assoc
       [
         ("v", `Int 1);
         ("expires", `Int 1);
         ("type", `String "file");
         ("key", `String hello_key);
         ("filename", `String "hello.txt");
       ])

let show label ?(body = true) ?range ?(query = []) ~token ~sub () =
  Printf.printf "\n=== %s\n" label;
  let* resp, rbody =
    Sh.handle ~token ~sub ~query:(fun k -> List.assoc_opt k query) ~range
  in
  let status = Cohttp.Response.status resp in
  Printf.printf "status: %d\n" (Cohttp.Code.code_of_status status);
  List.iter
    (fun h ->
      match Cohttp.Header.get (Cohttp.Response.headers resp) h with
        | Some v -> Printf.printf "%s: %s\n" h v
        | None -> ())
    [
      "content-type";
      "content-length";
      "content-range";
      "accept-ranges";
      "content-disposition";
    ];
  let+ s = Cohttp_lwt.Body.to_string rbody in
  if body then Printf.printf "body: %S\n" s
  else Printf.printf "body: %d bytes\n" (String.length s);
  s

let () =
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s && mkdir -p %s %s %s" root store_dir cache_dir
          data_dir));
  Lwt_main.run
    (let* () = Mf.ensure_root () in
     let* () = build_fixture () in

     let* _ = show "file share: whole file" ~token:"aa" ~sub:"" () in
     let* _ =
       show "file share: byte range" ~token:"aa" ~sub:"" ~range:"bytes=6-10" ()
     in
     let* _ =
       show "file share: suffix range" ~token:"aa" ~sub:"" ~range:"bytes=-7" ()
     in
     let* _ =
       show "file share: unsatisfiable range" ~token:"aa" ~sub:""
         ~range:"bytes=9999-10000" ()
     in

     let* _ = show "dir share: root listing" ~token:"bb" ~sub:"list" () in
     let* _ =
       show "dir share: sub listing" ~token:"bb" ~sub:"list"
         ~query:[("path", "sub")]
         ()
     in
     let* _ =
       show "dir share: file metadata" ~token:"bb" ~sub:"f"
         ~query:[("path", "hello.txt"); ("json", "1")]
         ()
     in
     let* _ =
       show "dir share: nested file bytes" ~token:"bb" ~sub:"f"
         ~query:[("path", "sub/inner.txt")]
         ()
     in
     let* _ =
       show "dir share: forced download" ~token:"bb" ~sub:"f"
         ~query:[("path", "hello.txt"); ("dl", "1")]
         ()
     in

     let* _ = show "bad token" ~token:"nothex!" ~sub:"" () in
     let* _ = show "unknown token" ~token:"deadbeef" ~sub:"" () in
     let* _ = show "expired token" ~token:"cc" ~sub:"" () in
     let* _ =
       show "path traversal rejected" ~token:"bb" ~sub:"f"
         ~query:[("path", "../../etc/passwd")]
         ()
     in
     let* _ =
       show "missing file" ~token:"bb" ~sub:"f" ~query:[("path", "nope.txt")] ()
     in

     let* zip =
       show "dir share: folder zip" ~body:false ~token:"bb" ~sub:"download" ()
     in
     let path = root ^ "/out.zip" in
     write_local path zip;
     (* A real unzip must accept what streamed out, and list exactly the shared
        tree. *)
     Printf.printf "unzip -t: %s\n"
       (if Sys.command (Printf.sprintf "unzip -qt %s >/dev/null 2>&1" path) = 0
        then "ok"
        else "FAILED");
     let names = root ^ "/names.txt" in
     ignore
       (Sys.command (Printf.sprintf "unzip -Z1 %s > %s 2>/dev/null" path names));
     let ic = open_in names in
     (try
        while true do
          print_endline ("member: " ^ input_line ic)
        done
      with End_of_file -> close_in ic);

     (* Share routes carry no credential, so the read bound is all that stands
        between a public burst and one buffer per concurrent block. With every
        slot held, a download must not produce a byte. *)
     Printf.printf "\n=== read bound\n";
     let held, release = Lwt.wait () in
     let occupied =
       List.init Share_server.read_slots_max (fun _ ->
           Lwt_bounded.use Share_server.read_slots (fun () -> held))
     in
     let* _, body =
       Sh.handle ~token:"aa" ~sub:"" ~query:(fun _ -> None) ~range:None
     in
     let download = Cohttp_lwt.Body.to_string body in
     let rec settle n =
       if n = 0 then Lwt.return_unit
       else
         let* () = Lwt.pause () in
         settle (n - 1)
     in
     let* () = settle 20 in
     (* Queued on the bound, not merely unfinished: without the slot the read
        would run straight through and nothing would be waiting here. *)
     Printf.printf "queued on the read bound: %b\n"
       (Lwt_bounded.waiting Share_server.read_slots > 0);
     Lwt.wakeup_later release ();
     let* s = download in
     let* () = Lwt.join occupied in
     Printf.printf "served once slots freed: %d bytes\n" (String.length s);

     (* Serving a share writes nothing into the manifest mirror and assembles
        nothing: the bytes it fetched are in the domain's chunk cache, which the
        mount shares. *)
     let rec count dir =
       if not (Sys.file_exists dir) then 0
       else
         Array.fold_left
           (fun n name ->
             let p = Filename.concat dir name in
             if Sys.is_directory p then n + count p else n + 1)
           0 (Sys.readdir dir)
     in
     Printf.printf "\n=== local footprint\n";
     Printf.printf "bytes served: %d\n"
       (Metrics.total Share_server.served_bytes);
     Printf.printf "chunk cache: %d chunks\n"
       (count (Cache_layout.chunks_dir ~cache_root:C.cache_root C.domain_name));
     Lwt.return_unit)
