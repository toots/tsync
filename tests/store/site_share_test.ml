(* Site shares (spec http-proxy §A9.9, security §6.5, 05 §4.11): created by
   the share operation, published by a real listener into its sites root on
   the first visit, and removed once the share is gone. *)

open Tsync_core
open Tsync_store
open Tsync_remote
module P = Tsync_http_proxy.Store_server
module Server = Tsync_http.Server

let p fmt = Printf.printf (fmt ^^ "\n")
let d = Domain_name.v "photos"

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-site-share-%d" (Unix.getpid ()))

let sites_root = Filename.concat root "sites"
let token c = String.make 32 c

let rec walk dir rel =
  List.concat_map
    (fun name ->
      let path = Filename.concat dir name and rel = rel ^ "/" ^ name in
      let st = Unix.stat path in
      (rel, st) :: (if st.st_kind = S_DIR then walk path rel else []))
    (List.sort compare (Option.value ~default:[] (Fs.readdir_opt dir)))

let tree dir rel =
  List.map
    (fun (rel, (st : Unix.stats)) ->
      if st.st_kind = S_DIR then rel ^ "/"
      else Printf.sprintf "%s %d bytes" rel st.st_size)
    (walk dir rel)

(* A static server running as another user reads them; Windows has no modes. *)
let readable_modes dir =
  Sys.win32
  || List.for_all
       (fun (_, (st : Unix.stats)) ->
         st.st_perm land 0o777 = if st.st_kind = S_DIR then 0o755 else 0o644)
       (walk dir "")

let show_site c =
  match tree (Filename.concat sites_root (token c)) "" with
    | [] -> p "  site %c: absent" c
    | lines -> List.iter (fun l -> p "  site %c%s" c l) lines

let route share =
  {
    P.name = "photos";
    domain = d;
    secret = String.make 40 's';
    read_only = false;
    domain_settings =
      {
        chunk = 4096;
        symlinks = `Skip;
        lease = 20.;
        quarantine = 200.;
        settle = 420.;
        entry_commands = 64;
        projector = None;
        extensions = [];
        vault_lock = Tsync_core.Vault_lock.none;
      };
    store = share;
    share = `Off;
    wake = ignore;
  }

let listener : Tsync_http_proxy.Proxy_options.listener =
  {
    port = 0;
    binds = [];
    tls = None;
    max_concurrent = None;
    max_put_body = 1 lsl 20;
    max_bulk_body = 1 lsl 20;
    max_body_memory = 1 lsl 24;
    max_share_responses = 8;
    max_zip_members = 100;
    sites = Some { root = sites_root; url = "https://sites.example" };
    push = None;
    limits = Server.default_limits;
  }

let () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let base = ref "http://127.0.0.1:1/s" in
      let inner = Local.create ~name:"main" (Filename.concat root "store") in
      let main =
        {
          inner with
          capabilities =
            (fun _ -> { Store.no_caps with share_url = Some !base });
        }
      in
      let composite =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore
          ~knowledge:{ is_index = (fun _ -> false); is_log = (fun _ -> false) }
          [{ name = "main"; role = Main; store = main }]
      in
      let module C = struct
        let domain = d
        let store = Composite.store composite
        let composite = composite
        let versioning = false
        let chunk_size_config = Some 8
        let max_downloads = 8
        let max_chunk_buffers = 4
      end in
      let module R = Remote.Make (C) in
      let module Share = Tsync_gc.Share.Make (C) in
      let put k v = C.store.put k (Bigstring.of_string v) in
      let folder parent name id =
        let id = Folder_id.v id in
        put (Key.child d parent name) (Folder.marker_body { name; id });
        put (Key.anchor d id) (Folder.anchor_body { parent; aname = name });
        id
      in
      let file parent name content =
        let m =
          R.upload_chunks ~name ~size:(String.length content) ~chunk_size:8
            ~times:{ Fs.mtime = 1_000_000_000; created = 1_000_000_000 }
            (fun i ->
              Bytes
                (Bigstring.of_string
                   (String.sub content (i * 8)
                      (min 8 (String.length content - (i * 8))))))
        in
        R.put_manifest (Key.child d parent name) (Manifest.rename m name)
      in
      let index = "<html><body>souvenirs</body></html>" in
      let site = folder Folder_id.root "site" "0000000000a1-1" in
      file site "index.html" index;
      file site "style.css" "body{}";
      file site "été 1.htm" "<p>été</p>";
      let img = folder site "img" "0000000000a2-1" in
      file img "a.gif" "GIF89a-pixels";
      let plain = folder Folder_id.root "plain" "0000000000a3-1" in
      file plain "readme.txt" "no pages here";
      let manifest t fields =
        put
          (Option.get (Key.share (token t)))
          (Yojson.Safe.to_string
             (`Assoc
                ([("v", `Int 1); ("domain", `String "photos")]
                @ fields
                @ [("filename", `String "x.zip")])))
      in
      let live = ("expires", `Int 9_999_999_999) in
      let proxy =
        P.create ~max_concurrent:4 ~listener
          [
            {
              (route C.store) with
              share =
                `Self (Tsync_http_proxy.Share_server.of_context (module C));
            };
          ]
      in
      let server =
        Server.serve
          [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
          (P.handle proxy)
      in
      let url =
        match Server.addresses server with
          | [ADDR_INET (_, port)] -> Printf.sprintf "http://127.0.0.1:%d" port
          | _ -> assert false
      in
      base := url ^ "/s";
      let get ?(headers = []) c =
        let r =
          Tsync_http.Client.request
            ~headers:(fun () -> headers)
            (Tsync_http.Client.endpoint url)
            ~meth:"GET"
            ("/s/" ^ token c)
        in
        let h k =
          Option.value ~default:"-" (Tsync_http.Codec.header r.headers k)
        in
        p "GET %c%s -> %d location %s cache-control %s content-type %s" c
          (match headers with [] -> "" | (_, v) :: _ -> " [" ^ v ^ "]")
          r.status
          (Text.replace_all ~sub:(token c) ~by:"<token>" (h "location"))
          (h "cache-control") (h "content-type")
      in
      let attempt what f =
        match f () with
          | () -> p "%s: done" what
          | exception Fail.E f -> p "%s: %s" what f.reason
      in
      let create ?(site = true) c rel =
        attempt
          (Printf.sprintf "create %s%s" rel (if site then " --site" else ""))
          (fun () -> ignore (Share.create ~token:(token c) ~site rel))
      in
      p "== creating a site share (05 §4.11)";
      create 'a' "plain";
      create 'a' "site/index.html";
      let linked = folder Folder_id.root "linked" "0000000000a4-1" in
      R.put_manifest
        (Key.child d linked "index.html")
        (Manifest.symlink ~name:"index.html"
           ~times:{ Fs.mtime = 0; created = 0 }
           "elsewhere.html");
      create 'a' "linked";
      create 'a' "site";
      show_site 'a';
      p "== the first visit publishes, then redirects (§A9.9)";
      Tsync_gc.Share.publish (url ^ "/s/" ^ token 'a');
      show_site 'a';
      p "files 644, folders 755: %b"
        (readable_modes (Filename.concat sites_root (token 'a')));
      p "record written: %b"
        (C.store.get_opt (Option.get (Key.share_site (token 'a'))) <> None);
      let published rel =
        Fs.read_file
          (Filename.concat (Filename.concat sites_root (token 'a')) rel)
      in
      p "byte-exact: %b"
        (published "index.html" = index
        && published "img/a.gif" = "GIF89a-pixels"
        && published "été 1.htm" = "<p>été</p>");
      get ~headers:[("accept", "text/html")] 'a';
      get ~headers:[("user-agent", "WhatsApp/2.24")] 'a';
      p "== a published site is not published again";
      Sys.remove
        (Filename.concat (Filename.concat sites_root (token 'a')) "img/a.gif");
      get 'a';
      show_site 'a';
      p "== a publication cut short resumes; the copy is the folder alone";
      ignore (C.store.delete (Option.get (Key.share_site (token 'a'))));
      let in_copy rel =
        Filename.concat (Filename.concat sites_root (token 'a')) rel
      in
      let write rel content ~mtime =
        Out_channel.with_open_bin (in_copy rel) (fun oc ->
            output_string oc content);
        Option.iter (fun t -> Unix.utimes (in_copy rel) t t) mtime
      in
      let same_size_as s = String.make (String.length s) 'x' in
      write "index.html" (same_size_as index)
        ~mtime:(Some (Fs.seconds 1_000_000_000));
      write "style.css" (same_size_as "body{}") ~mtime:None;
      write "old.html" "a stale page" ~mtime:None;
      get 'a';
      show_site 'a';
      p "same size and time kept: %b, same size at another time rewritten: %b"
        (published "index.html" <> index)
        (published "style.css" = "body{}");
      p "== an entry of the other kind is replaced";
      ignore (C.store.delete (Option.get (Key.share_site (token 'a'))));
      Fs.rm_rf (in_copy "img");
      write "img" "a file where a folder goes" ~mtime:None;
      Fs.rm_rf (in_copy "style.css");
      Fs.mkdir_p (in_copy "style.css");
      get 'a';
      show_site 'a';
      p "== a copy missing from the sites root is published again";
      Fs.rm_rf (Filename.concat sites_root (token 'a'));
      get 'a';
      show_site 'a';
      p "== a folder share that is not a site";
      create ~site:false 'b' "site";
      get ~headers:[("accept", "text/html")] 'b';
      show_site 'b';
      p "== manifests a reader refuses (02 §2.14)";
      manifest 'c'
        [
          ("type", `String "dir");
          ("folderId", `String "0000000000a1-1");
          ("site", `String "index.html");
          live;
        ];
      get 'c';
      manifest 'e'
        [
          ("type", `String "file");
          ("key", `String (Key.to_string (Key.child d site "index.html")));
          ("site", `Bool true);
          live;
        ];
      get 'e';
      p "== a share that is gone has its site removed (security §6.5)";
      let planted c =
        let dir = Filename.concat sites_root (token c) in
        Fs.mkdir_p dir;
        Out_channel.with_open_bin (Filename.concat dir "index.html") (fun oc ->
            output_string oc "old")
      in
      planted 'f';
      get 'f';
      show_site 'f';
      manifest '7'
        [
          ("type", `String "dir");
          ("folderId", `String "0000000000a1-1");
          ("site", `Bool true);
          ("expires", `Int 1);
        ];
      planted '7';
      get '7';
      show_site '7';
      p "== a share that cannot be read keeps its site";
      put (Option.get (Key.share (token '8'))) "{not json";
      planted '8';
      get '8';
      show_site '8';
      p "== revoking asks the link, which removes the site";
      attempt "revoke a" (fun () -> ignore (Share.revoke (token 'a')));
      show_site 'a';
      p "record left: %b"
        (C.store.get_opt (Option.get (Key.share_site (token 'a'))) <> None);
      create '9' "site";
      Tsync_gc.Share.publish (url ^ "/s/" ^ token '9');
      Server.close server;
      p "== revoking with the server gone leaves the site and says so";
      (match Share.revoke (token '9') with
        | found -> p "revoke 9: %b" found
        | exception Fail.E f ->
            p "revoke 9: %s, says until when %b" (Fail.kind_name f.kind)
              (Text.contains f.reason "stays readable until"));
      p "manifest left: %b"
        (C.store.get_opt (Option.get (Key.share (token '9'))) <> None);
      show_site '9');
  Fs.rm_rf root
