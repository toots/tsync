(* android §9, Ownership and boot: two domains booted in one process, each
   answering its own requests, handles and notices, and a failed boot leaving
   the other serving. *)

open Tsync_core
open Tsync_android

let p fmt = Printf.printf (fmt ^^ "\n%!")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-domains-%d" (Unix.getpid ()))

let field j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None
let text j k = match field j k with Some (`String s) -> s | _ -> "?"

let request domain fields =
  Yojson.Safe.from_string
    (Android_host.request domain (Yojson.Safe.to_string (`Assoc fields)))

let answer j =
  match field j "ok" with
    | Some (`Bool true) -> "ok"
    | _ -> Printf.sprintf "%s: %s" (text j "code") (text j "error")

let notices = ref []
let notices_m = Mutex.create ()

let () =
  ignore
    (Thread.create
       (fun () ->
         while true do
           let n = Yojson.Safe.from_string (Android_host.next_notice ()) in
           Mutex.protect notices_m (fun () -> notices := n :: !notices)
         done)
       ())

let notice_from domain =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec wait () =
    let found =
      Mutex.protect notices_m (fun () ->
          List.exists (fun n -> text n "domain" = domain) !notices)
    in
    if found || Unix.gettimeofday () > deadline then found
    else (
      Thread.delay 0.05;
      wait ())
  in
  wait ()

let write domain name body =
  let staging = Filename.concat (Sys.getenv "HOME") (domain ^ "-" ^ name) in
  Fs.write_file_for_test staging body;
  let j =
    request domain
      [
        ("action", `String "write");
        ("parentRef", `String "root");
        ("name", `String name);
        ("staging", `String staging);
        ("await", `Bool true);
      ]
  in
  match Option.bind (field j "item") (fun i -> field i "ref") with
    | Some (`String r) -> r
    | _ -> failwith ("write: " ^ Yojson.Safe.to_string j)

let stat domain name =
  answer
    (request domain
       [
         ("action", `String "stat");
         ("parentRef", `String "root");
         ("name", `String name);
       ])

let read handle =
  let buffer = Bigstring.create 64 in
  let n = Android_host.read handle ~off:0 buffer in
  if n < 0 then string_of_int n else Bigstring.to_string ~off:0 ~len:n buffer

let domain ?(frontends = {|["android"]|}) name =
  Printf.sprintf
    {|{"name":"%s","symlinks":"skip","versioning":true,"extensions":[],
       "frontends":%s,
       "backends":[{"type":"local","name":"main","role":"main","path":"%s/%s"}]}|}
    name frontends root name

let () =
  Fs.rm_rf root;
  List.iter
    (fun (var, dir) ->
      let dir = Filename.concat root dir in
      Fs.mkdir_p ~perm:0o700 dir;
      Unix.putenv var dir)
    [("HOME", "home"); ("XDG_DATA_HOME", "data"); ("XDG_CACHE_HOME", "cache")];
  Unix.putenv "TSYNC_CONFIG_JSON"
    (Printf.sprintf {|{"name":"phone","domains":[%s,%s,%s]}|} (domain "docs")
       (domain "photos")
       (domain ~frontends:{|["fuse"]|} "laptop"));
  Tsync_android_bridge.Android_bridge.started ();
  p "== one domain booted";
  p "  %-30s %S" "boot docs" (Android_host.boot "docs");
  p "  %-30s %s" "request on photos"
    (answer
       (request "photos" [("action", `String "stat"); ("ref", `String "root")]));
  p "  %-30s %d" "open on photos" (Android_host.open_ "photos" "root");
  p "  %-30s %s" "status of photos" (Android_host.status "photos");
  p "== a boot that fails";
  p "  %-30s %S" "boot laptop" (Android_host.boot "laptop");
  p "  %-30s %s" "docs still answers"
    (answer
       (request "docs" [("action", `String "stat"); ("ref", `String "root")]));
  p "== both booted";
  p "  %-30s %S" "boot photos" (Android_host.boot "photos");
  p "  %-30s %S" "boot docs again" (Android_host.boot "docs");
  let in_docs = write "docs" "a.txt" "from docs" in
  ignore (write "photos" "b.txt" "from photos");
  p "  %-30s %s" "docs has a.txt" (stat "docs" "a.txt");
  p "  %-30s %s" "docs has b.txt" (stat "docs" "b.txt");
  p "  %-30s %s" "photos has b.txt" (stat "photos" "b.txt");
  p "  %-30s %b" "a notice names photos" (notice_from "photos");
  p "== handles";
  p "  %-30s %d" "docs' file opened in photos"
    (Android_host.open_ "photos" in_docs);
  let handle = Android_host.open_ "docs" in_docs in
  p "  %-30s %s" "read" (read handle);
  ignore (Android_host.close handle);
  p "  %-30s %s" "read after close" (read handle);
  Test_support.finish root;
  exit 0
