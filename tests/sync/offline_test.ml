(* Offline is normal (README §1 constraint 3): with a store that never answers,
   an owner starts and every local operation completes without waiting on it. *)

open Tsync_core
open Tsync_store
open Tsync_sync

let p fmt = Printf.printf fmt

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-offline-%d" (Unix.getpid ()))

let d = Domain_name.v "docs"

let knowledge =
  { Composite.is_index = (fun _ -> false); is_journal = (fun _ -> false) }

(* Every call waits forever, as a store behind a dead link does until its
   timeouts fire. *)
let silent (s : Store.t) : Store.t =
  let never () =
    Rt.sleep 1e9;
    assert false
  in
  {
    s with
    put = (fun ?mode:_ _ _ -> never ());
    put_if_absent = (fun _ _ -> never ());
    get_opt = (fun _ -> never ());
    get_range = (fun _ _ _ -> never ());
    head_opt = (fun _ -> never ());
    delete = (fun _ -> never ());
    delete_multi = (fun _ -> never ());
    copy = (fun _ _ -> never ());
    list_prefix = (fun ?max_keys:_ _ -> never ());
    watch = (fun _ _ -> never ());
    get_many = None;
    list_many = None;
  }

let client ~poll : (module Engine.S) =
  let data_dir = Filename.concat root "data" in
  let store =
    silent (Local.create ~name:"main" (Filename.concat root "store"))
  in
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
    let cache_root = Filename.concat root "cache"
    let data_dir = data_dir
    let client_uuid = Tsync_checkout.Identity.client_uuid data_dir
    let client_name = "offline"
    let cache_chunk_size = 8
    let max_cache = None
    let max_uploads = 1
    let read_only = false
    let symlinks = `Keep
    let lazy_tree = false
  end in
  let e = (module Engine.Make (C) : Engine.S) in
  let (module E) = e in
  E.start ~poll_journal:poll ();
  e

(* The domain as the service builds it, its store an http-proxy at an address
   nothing answers. *)
let proxied () : (module Engine.S) =
  let config =
    Tsync_config.Config.of_string
      {|{"domains":[{"name":"docs","symlinks":"keep","versioning":true,"frontends":["http-proxy"],
        "backends":[{"type":"http-proxy","name":"main","role":"main",
          "url":"https://10.255.255.1:8443",
          "secret":"0123456789abcdef0123456789abcdef0123456789abcdef"}]}]}|}
  in
  let dom =
    Tsync_domain.Domain.build ~owner:true config (List.hd config.domains)
  in
  let e = Tsync_domain.Domain.engine dom in
  let (module E) = e in
  E.start ();
  e

let within label f =
  match Rt.with_timeout 5. f with
    | () -> p "  %-28s done\n" label
    | exception Rt.Timeout -> p "  %-28s STILL WAITING after 5 s\n" label
    | exception e -> p "  %-28s failed: %s\n" label (Printexc.to_string e)

let () =
  Fs.rm_rf root;
  (* A domain the service builds files its state under these. *)
  List.iter
    (fun (var, dir) ->
      let dir = Filename.concat root dir in
      Fs.mkdir_p ~perm:0o700 dir;
      Unix.putenv var dir)
    [
      ("HOME", "home");
      ("XDG_DATA_HOME", "xdg-data");
      ("XDG_CACHE_HOME", "xdg-cache");
    ];
  let mode = if Array.length Sys.argv > 1 then Sys.argv.(1) else "" in
  let poll = mode = "poll" in
  Rt.run_sync (fun () ->
      p "== %s\n"
        (if mode = "proxy" then "an http-proxy store nothing answers"
         else
           "a store that never answers, journal polling "
           ^ if poll then "on" else "off");
      let (module E) = if mode = "proxy" then proxied () else client ~poll in
      within "mkdir" (fun () -> E.mkdir "dir" ~exclusive:false);
      within "create and write" (fun () ->
          E.create "dir/a.txt" ~exclusive:false;
          E.write "dir/a.txt" ~off:0 (Bigstring.of_string "offline");
          E.close "dir/a.txt");
      within "rename" (fun () ->
          E.rename ~src:"dir/a.txt" ~dst:"dir/b.txt" ~exclusive:false);
      within "delete" (fun () -> E.delete "dir/b.txt"));
  exit 0
