(* The reserved root folder (spec 01 §2.3): records another client wrote under
   /.tsync-ext/ are absent from the owner's rows, listings and feed, from
   export, rsync and import, and every request naming them is INVALID. *)

open Tsync_core
open Tsync_ipc
open Tsync_store
open Tsync_sync
open Tsync_owner

let p fmt = Printf.printf (fmt ^^ "\n%!")

(* Short: on macOS the owner's socket lives under the home directory. *)
let root = Printf.sprintf "/tmp/tsync-reserved-%d" (Unix.getpid ())
let home = Filename.concat root "home"

let () =
  Fs.rm_rf root;
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let socket = Filename.concat root "data/tsync/test.sock"
let d = Domain_name.v "docs"

let config =
  Tsync_config.Config.of_string
    (Printf.sprintf
       {|{"name":"test","domains":[
  {"name":"docs","symlinks":"keep","versioning":true,"extensions":[],"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]}]}|}
       root)

let knowledge =
  { Composite.is_index = (fun _ -> false); is_log = (fun _ -> false) }

(* The client whose extension layer writes the records. *)
let client name : (module Engine.S) * (module Tsync_remote.Context.S) =
  let data_dir = Filename.concat root (name ^ "/data") in
  let store = Local.create ~name:"main" (Filename.concat root "store") in
  let composite =
    Composite.create ~domain:d ~data_dir ~owner:true ~poke:ignore ~knowledge
      [{ name = "main"; role = Main; store }]
  in
  let module C = struct
    let domain = d
    let store = Composite.store composite
    let composite = composite
    let versioning = true
    let chunk_size_config = Some 4
    let max_downloads = 4
    let max_chunk_buffers = 4
    let cache_root = Filename.concat root (name ^ "/cache")
    let data_dir = data_dir
    let client_uuid = Tsync_checkout.Identity.client_uuid data_dir
    let client_name = name
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
    let projects_all = false
    let settings _ = (Tuning.default, symlinks)
  end in
  ((module Engine.Make (C)), (module C : Tsync_remote.Context.S))

let refused label f =
  match f () with
    | _ -> p "%-30s accepted" label
    | exception Fail.E f ->
        p "%-30s %s: %s" label (Fail.code f.kind)
          (Text.replace_all ~sub:(root ^ "/") ~by:"" f.reason)

let names (module E : Engine.S) dir =
  String.concat " "
    (List.map (fun (e : E.entry) -> e.name) (E.list_children dir))

let local_listing dir =
  let rec walk rel =
    let path = if rel = "" then dir else Filename.concat dir rel in
    if Sys.is_directory path then
      List.concat_map
        (fun n -> walk (if rel = "" then n else Filename.concat rel n))
        (List.sort compare (Array.to_list (Sys.readdir path)))
    else [rel]
  in
  String.concat " " (walk "")

let file base rel body =
  let path = Filename.concat base rel in
  Fs.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> output_string oc body)

let ask fields =
  Ipc.call socket
    (`Assoc
       (("domain", `String "docs")
       :: List.map (fun (k, v) -> (k, `String v)) fields))

let answer label r =
  match Ipc.field r "error" with
    | Some e -> p "%-30s %s: %s" label (Option.get (Ipc.field r "code")) e
    | None -> p "%-30s ok" label

let member j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None

let rec wait_serving n =
  match Ipc.call socket (`Assoc [("action", `String "ping")]) with
    | _ -> ()
    | exception _ when n > 0 ->
        Rt.sleep 0.05;
        wait_serving (n - 1)

let engine_checks (module A : Engine.S) ctx =
  let put path body =
    A.create path ~exclusive:false;
    A.write path ~off:0 (Bigstring.of_string body);
    A.close path
  in
  A.mkdir ".tsync-ext" ~exclusive:false;
  A.mkdir ".tsync-ext/totp" ~exclusive:false;
  put ".tsync-ext/totp/r1" "sealed";
  put "a.txt" "a";
  A.mkdir "sub" ~exclusive:false;
  A.mkdir "sub/.tsync-ext" ~exclusive:false;
  put "sub/.tsync-ext/b.txt" "b";
  A.drain ~grace:10. ();
  p "== engine listings";
  p "root: [%s]" (names (module A) "");
  p ".tsync-ext: [%s]" (names (module A) ".tsync-ext");
  p ".tsync-ext/totp: [%s]" (names (module A) ".tsync-ext/totp");
  p "sub: [%s]" (names (module A) "sub");
  p "== export";
  let module X = Export.Make ((val ctx : Tsync_remote.Context.S)) in
  let cache_root = Filename.concat root "A/cache" in
  let out = Filename.concat root "exported" in
  refused "export the root" (fun () ->
      ignore (X.export ~cache_root ~dst:out [""]));
  p "  [%s]" (local_listing out);
  refused "export .tsync-ext/totp" (fun () ->
      X.export ~cache_root ~dst:(Filename.concat root "x") [".tsync-ext/totp"]);
  p "== rsync";
  let local path : Rsync_plan.endpoint = { side = Local; path } in
  let domain path : Rsync_plan.endpoint = { side = Domain; path } in
  let rs src dst = ignore (A.rsync ~src ~dst ()) in
  let out = Filename.concat root "rsynced" in
  refused "the root out" (fun () -> rs (domain "") (local out));
  p "  [%s]" (local_listing out);
  refused "from .tsync-ext" (fun () ->
      rs (domain ".tsync-ext/totp") (local (Filename.concat root "y")));
  refused "into .tsync-ext" (fun () ->
      rs (local (Filename.concat root "rsynced/sub")) (domain ".tsync-ext/z"));
  let src = Filename.concat root "src" in
  file src ".tsync-ext/totp/forged" "x";
  file src "c.txt" "c";
  refused "a source holding .tsync-ext" (fun () -> rs (local src) (domain ""));
  refused "the same into a folder" (fun () -> rs (local src) (domain "in"));
  p "  in: [%s] in/.tsync-ext: [%s]"
    (names (module A) "in")
    (names (module A) "in/.tsync-ext");
  p "== import";
  refused "a source holding .tsync-ext" (fun () -> ignore (A.import src));
  A.drain ~grace:10. ();
  p "  root: [%s]" (names (module A) "");
  p "  .tsync-ext/totp: [%s]" (names (module A) ".tsync-ext/totp")

let () =
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      let a, ctx = client "A" in
      let (module A) = a in
      A.start ~background:false ();
      engine_checks a ctx;
      let ext_id =
        Folder_id.to_string (Option.get (A.folder_id ".tsync-ext"))
      in
      let owner =
        Rt.async (fun () ->
            Owner.run ~socket config config.Tsync_config.Config.domains)
      in
      wait_serving 100;
      (* The owner's own arrival is settled first: the feed then holds only
         the writes below. *)
      ignore (ask [("action", "sync")]);
      let cursor =
        Option.get (Ipc.field (ask [("action", "cursor")]) "cursor")
      in
      let module Y = (val a) in
      Y.create "late.txt" ~exclusive:false;
      Y.close "late.txt";
      Y.mkdir ".tsync-ext/passwords" ~exclusive:false;
      Y.create ".tsync-ext/passwords/r2" ~exclusive:false;
      Y.close ".tsync-ext/passwords/r2";
      Y.drain ~grace:10. ();
      answer "sync" (ask [("action", "sync")]);
      p "== owner";
      let rows r =
        match member r "items" with
          | Some (`List l) ->
              String.concat " "
                (List.map (fun i -> Option.get (Ipc.field i "name")) l)
          | _ -> Yojson.Safe.to_string r
      in
      p "list_dir root: [%s]"
        (rows (ask [("action", "list_dir"); ("ref", "root")]));
      p "list_all: [%s]" (rows (ask [("action", "list_all")]));
      answer "stat rel .tsync-ext"
        (ask [("action", "stat"); ("rel", ".tsync-ext")]);
      answer "stat rel record"
        (ask [("action", "stat"); ("rel", ".tsync-ext/totp/r1")]);
      answer "stat d:<its id>"
        (ask [("action", "stat"); ("ref", "d:" ^ ext_id)]);
      answer "mkdir .tsync-ext"
        (ask
           [("action", "mkdir"); ("parentRef", "root"); ("name", ".tsync-ext")]);
      answer "stat sub/.tsync-ext/b.txt"
        (ask [("action", "stat"); ("rel", "sub/.tsync-ext/b.txt")]);
      answer "rename a.txt onto it"
        (ask
           [
             ("action", "rename");
             ("ref", "f:" ^ Names.root_id ^ "/a.txt");
             ("parentRef", "root");
             ("name", ".tsync-ext");
           ]);
      answer "share it" (ask [("action", "share"); ("rel", ".tsync-ext")]);
      answer "revert a record"
        (ask [("action", "revert"); ("rel", ".tsync-ext/totp/r1")]);
      let feed = ask [("action", "changes_since"); ("arg", cursor)] in
      (match member feed "ops" with
        | Some (`List ops) ->
            p "feed: [%s]"
              (String.concat " "
                 (List.map
                    (fun o -> Option.value ~default:"?" (Ipc.field o "name"))
                    ops))
        | _ -> p "feed: %s" (Yojson.Safe.to_string feed));
      p "feed unnamed: %s"
        (Option.value ~default:"-"
           (Option.map Yojson.Safe.to_string (member feed "unnamed")));
      ignore (ask [("action", "stop")]);
      p "exit status %d" (Rt.Promise.await owner));
  Fs.rm_rf root
