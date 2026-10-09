open Tsync_core
open Tsync_store
open Tsync_remote
module S = Tsync_http_proxy.Share_server
module Server = Tsync_http.Server

let p fmt = Printf.printf (fmt ^^ "\n")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-share-%d" (Unix.getpid ()))

let body_text (r : Server.response) =
  match r.body with
    | Empty -> ""
    | String s -> s
    | Bigstring b | Held { bytes = b; _ } -> Bigstring.to_string b
    | Stream { write; _ } ->
        let b = Buffer.create 64 in
        write (fun c -> Buffer.add_string b (Bigstring.to_string c));
        Buffer.contents b

let contains s sub =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
  in
  go 0

(* §A9.3 through [handle], on a real store: three shared files of one domain. *)
let routes () =
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let d = Domain_name.v "photos" in
      let main = Local.create ~name:"main" (Filename.concat root "store") in
      let composite =
        Composite.create ~domain:d
          ~data_dir:(Filename.concat root "data")
          ~owner:true ~poke:ignore
          ~knowledge:
            { is_index = (fun _ -> false); is_journal = (fun _ -> false) }
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
      let share token name content =
        (match content with
          | Some content ->
              let m =
                R.upload_chunks ~name ~size:(String.length content)
                  ~chunk_size:8 ~mtime:1. (fun i ->
                    Bytes
                      (Bigstring.of_string
                         (String.sub content (i * 8)
                            (min 8 (String.length content - (i * 8))))))
              in
              R.publish ~parent:Folder_id.root ~leaf:name m
          | None -> ());
        C.store.put
          (Option.get (Key.share token))
          (Bigstring.of_string
             (Yojson.Safe.to_string
                (`Assoc
                   [
                     ("v", `Int 1);
                     ("domain", `String "photos");
                     ("type", `String "file");
                     ( "key",
                       `String (Key.to_string (Key.child d Folder_id.root name))
                     );
                     ("filename", `String name);
                     ("expires", `Int 9_999_999_999);
                   ])))
      in
      share "a1" "</script>.mp3" (Some "0123456789abcdefXYZ");
      share "a2" "notes.txt" (Some "plain words");
      share "a3" "gone.mp4" None;
      let t = S.of_context (module C) in
      let get ?accept token sub params =
        let r =
          S.handle t ~max_zip_members:10
            {
              Server.meth = "GET";
              target = "";
              path = "";
              query = "";
              headers =
                (match accept with Some a -> [("accept", a)] | None -> []);
              peer = "";
              body_length = `Length 0;
            }
            ~token ~sub params
        in
        let header k = Option.value ~default:"-" (List.assoc_opt k r.headers) in
        let body = body_text r in
        p "%s /%s%s%s -> %d%s %s | %s | %s" token sub
          (if params = [] then "" else "?json=1")
          (match accept with Some a -> " [" ^ a ^ "]" | None -> "")
          r.status
          (if header "vary" = "accept" then " vary" else "")
          (header "content-type")
          (header "content-disposition")
          (if String.starts_with ~prefix:"text/html" (header "content-type")
           then
             Printf.sprintf "page: file mode %b, raw name %b"
               (contains body {|"file":true|})
               (contains body "</script>.mp3")
           else String.trim body)
      in
      p "== routes of a file share (§A9.3)";
      get ~accept:"text/html,application/xhtml+xml,*/*;q=0.8" "a1" "" [];
      get ~accept:"image/*,*/*;q=0.8" "a1" "" [];
      get "a1" "" [];
      get "a1" "f" [];
      get "a1" "f" [("json", "1")];
      get "a1" "download" [];
      get "a1" "list" [];
      get "a2" "" [];
      get "a2" "f" [];
      get ~accept:"text/html" "a2" "" [];
      get ~accept:"text/html" "a3" "" []);
  Fs.rm_rf root

let () =
  p "== ranges of a 39-byte file (§A9.5)";
  List.iter
    (fun h ->
      p "%-16s %s"
        (Option.value ~default:"(none)" h)
        (match S.parse_range 39 h with
          | `Whole -> "whole"
          | `Unsatisfiable -> "416"
          | `Range (a, b) -> Printf.sprintf "bytes %d-%d/39" a b))
    [
      None;
      Some "bytes=6-10";
      Some "bytes=6-";
      Some "bytes=-5";
      Some "bytes=-100";
      Some "bytes=30-100";
      Some "bytes=39-";
      Some "bytes=10-6";
      Some "bytes=1-2,4-5";
      Some "bytes=+1-2";
      Some "items=1-2";
      Some "bytes=-0";
    ];
  p "== content-disposition (security §13)";
  p "%s" (S.disposition "attachment" "report.pdf");
  p "%s" (S.disposition "inline" "a\"b\\c ✓\n.txt");
  p "== files that open the viewer page (§A9.3)";
  List.iter
    (fun name -> p "%-12s %b" name (S.media name))
    [
      "a.MP3";
      "a.mp4";
      "a.jpg";
      "a.pdf";
      "a.txt";
      "a.html";
      "a.json";
      "a.bin";
      "mp3";
    ];
  routes ();
  p "== single-pass templating";
  p "%s" (S.fill "<h1>__A__</h1> __B__" [("__A__", "__B__"); ("__B__", "b")]);
  p "== JSON inside a script";
  p "%s"
    (S.script_json (`Assoc [("title", `String "</script><b>&\xe2\x80\xa8")]))
