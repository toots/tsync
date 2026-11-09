(* The android frontend's pulled tree through the bridge a host calls: one
   owner booted in-process, a peer writing to the same store, and a store that
   can be made silent. *)

open Tsync_core
open Tsync_store
open Tsync_sync
open Tsync_android

let p fmt = Printf.printf (fmt ^^ "\n%!")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-lazy-%d" (Unix.getpid ()))

let store_path = Filename.concat root "store"

(* 09 §5.3: doubles over the real local store. Under [Hung] a call waits until
   the link returns, then goes through; under [Bodies_hung] only a chunk's read
   does; under [Down] it answers unreachable.
   Listings and reads of the log are counted on entry: a pull makes one or
   the other. *)
let mode : [ `Up | `Hung | `Bodies_hung | `Down ] Atomic.t = Atomic.make `Up
let listings = Atomic.make 0

let gated (s : Store.t) : Store.t =
  let rec gate ?(body = false) f =
    match Atomic.get mode with
      | `Up -> f ()
      | `Bodies_hung when not body -> f ()
      | `Hung | `Bodies_hung ->
          Rt.sleep 0.05;
          gate ~body f
      | `Down -> Fail.raise_ Fail.Unreachable "the store is down"
  in
  let body k = Key.chunk_of k <> None in
  {
    s with
    put = (fun ?mode k b -> gate (fun () -> s.put ?mode k b));
    put_if_absent = (fun k b -> gate (fun () -> s.put_if_absent k b));
    get_opt =
      (fun k ->
        if Key.is_log_entry k || Key.leaf k = "tree-head" then
          Atomic.incr listings;
        gate ~body:(body k) (fun () -> s.get_opt k));
    get_range = (fun k o l -> gate ~body:(body k) (fun () -> s.get_range k o l));
    head_opt = (fun k -> gate (fun () -> s.head_opt k));
    delete = (fun k -> gate (fun () -> s.delete k));
    delete_multi = (fun ks -> gate (fun () -> s.delete_multi ks));
    copy = (fun a b -> gate (fun () -> s.copy a b));
    list_prefix =
      (fun ?max_keys prefix ->
        Atomic.incr listings;
        gate (fun () -> s.list_prefix ?max_keys prefix));
    watch = (fun k t -> gate (fun () -> s.watch k t));
    get_many = None;
    list_many = None;
    fast_read = Fun.const false;
    local_path = None;
    health = Health.always_up;
  }

let () =
  let local = Option.get (Driver.find "local") in
  Driver.register "gated"
    {
      local with
      create =
        (fun ?spill ~domain ~admission ~name fields ->
          gated (local.create ?spill ~domain ~admission ~name fields));
    }

let d = Domain_name.v "docs"

let peer : (module Engine.S) Lazy.t =
  lazy
    (let data_dir = Filename.concat root "peer/data" in
     let store = Local.create ~name:"main" store_path in
     let composite =
       Composite.create ~domain:d ~data_dir ~owner:true ~poke:ignore
         ~knowledge:{ is_index = (fun _ -> false); is_log = (fun _ -> false) }
         [{ name = "main"; role = Main; store }]
     in
     let module C = struct
       let domain = d
       let store = Composite.store composite
       let composite = composite
       let versioning = true
       let chunk_size_config = None
       let max_downloads = 4
       let max_chunk_buffers = 4
       let cache_root = Filename.concat root "peer/cache"
       let data_dir = data_dir
       let client_uuid = Tsync_checkout.Identity.client_uuid data_dir
       let client_name = "peer"
       let cache_chunk_size = Tsync_checkout.Cache.default_cache_chunk_size
       let max_cache = None
       let max_uploads = 1
       let read_only = false
       let symlinks = `Skip
       let lazy_tree = false
       let projects_all = false
       let settings _ = (Tuning.default, symlinks)
     end in
     let e = (module Engine.Make (C) : Engine.S) in
     let (module E) = e in
     E.start ~background:false ();
     e)

let peer_does f =
  Rt.run_sync (fun () ->
      let (module E) = Lazy.force peer in
      ignore (E.resync ());
      f (module E : Engine.S);
      E.drain ~grace:10. ())

let peer_writes path content =
  peer_does (fun (module E) ->
      E.create path ~exclusive:false;
      E.truncate path 0;
      E.write path ~off:0 (Bigstring.of_string content);
      E.close path)

(* Folder ids, file ids and content hashes are shown as placeholders. *)
let ids = Hashtbl.create 16

let placeholder kind id =
  match Hashtbl.find_opt ids id with
    | Some k -> k
    | None ->
        let k = Printf.sprintf "<%s%d>" kind (Hashtbl.length ids + 1) in
        Hashtbl.replace ids id k;
        k

let scrub_ref r =
  match String.index_opt r ':' with
    | Some 1 ->
        String.sub r 0 2
        ^ placeholder
            (if r.[0] = 'd' then "folder" else "file")
            (String.sub r 2 (String.length r - 2))
    | _ -> r

let field j k = match j with `Assoc l -> List.assoc_opt k l | _ -> None
let text j k = match field j k with Some (`String s) -> s | _ -> "?"

let request fields =
  Yojson.Safe.from_string
    (Android_host.request "docs" (Yojson.Safe.to_string (`Assoc fields)))

let action name fields = request (("action", `String name) :: fields)
let s k v = (k, `String v)

let outcome j =
  match field j "ok" with
    | Some (`Bool true) -> "ok"
    | _ -> Printf.sprintf "%s (%s)" (text j "code") (text j "error")

let row j =
  Printf.sprintf "%s%s%s" (text j "name")
    (if text j "kind" = "dir" then "/" else "")
    (if field j "isUploaded" = Some (`Bool false) then " (not uploaded)" else "")

(* A listing: its rows, whether it read the store, and its freshness flags. *)
let list ?(extra = []) label ref_ =
  let before = Atomic.get listings in
  let j = action "list_dir" (s "ref" ref_ :: extra) in
  let read =
    if Atomic.get listings > before then "read the store" else "no read"
  in
  (match field j "items" with
    | Some (`List items) ->
        p "  %-34s [%s] %s%s%s" label
          (String.concat ", " (List.map row items))
          read
          (if field j "pulledAt" = None then ", never pulled" else "")
          (if field j "outdated" = Some (`Bool true) then ", outdated" else "")
    | _ -> p "  %-34s %s, %s" label (outcome j) read);
  j

let ref_of listing name =
  match field listing "items" with
    | Some (`List items) ->
        text (List.find (fun i -> text i "name" = name) items) "ref"
    | _ -> "?"

(* The notice sink: a host thread blocked on the bridge. *)
let notices = ref []
let notices_m = Mutex.create ()

let () =
  ignore
    (Thread.create
       (fun () ->
         while true do
           let n = Android_host.next_notice () in
           Mutex.protect notices_m (fun () -> notices := n :: !notices)
         done)
       ())

(* Notices since the last call, as a set: background pulls send theirs when
   they complete. *)
let show_notices label =
  Thread.delay 0.3;
  let got =
    Mutex.protect notices_m (fun () ->
        let got = !notices in
        notices := [];
        got)
  in
  let render n =
    let j = Yojson.Safe.from_string n in
    match field j "refs" with
      | Some (`List refs) ->
          List.map
            (function
              | `String r -> text j "event" ^ " " ^ scrub_ref r | _ -> "?")
            refs
      | _ -> [text j "event"]
  in
  p "  %-34s {%s}" label
    (String.concat ", " (List.sort_uniq compare (List.concat_map render got)))

let read_all ref_ =
  let handle = Android_host.open_ "docs" ref_ in
  if handle < 0 then Printf.sprintf "errno %d" (-handle)
  else (
    let buffer = Bigstring.create 64 in
    let n = Android_host.read handle ~off:0 buffer in
    ignore (Android_host.close handle);
    if n < 0 then Printf.sprintf "errno %d" (-n)
    else Printf.sprintf "%S" (Bigstring.to_string ~off:0 ~len:n buffer))

let staged name content =
  let path = Filename.concat (Sys.getenv "HOME") name in
  Fs.write_file_for_test path content;
  path

let outdate ref_path =
  (* A view older than view_max_age: its pull marker says so. *)
  let marker =
    List.fold_left Filename.concat
      (Tsync_config.Paths.cache_root ())
      (["docs"; "manifests"] @ ref_path @ [".tsync-pulled"])
  in
  Fs.write_file_for_test marker "1000"

(* Publication is the queue's, so its notice is waited for, not timed. *)
let until_uploaded name =
  let uploaded () =
    field (action "stat" [s "parentRef" "root"; s "name" name]) "isUploaded"
    = Some (`Bool true)
  in
  let deadline = Unix.gettimeofday () +. 20. in
  while (not (uploaded ())) && Unix.gettimeofday () < deadline do
    Thread.delay 0.05
  done

(* A folder always reads as uploaded and its publication retries on its own
   backoff, so the peer is asked until it lists it. *)
let until_peer_sees name =
  let deadline = Unix.gettimeofday () +. 20. in
  let rec ask () =
    let names = ref [] in
    peer_does (fun (module E) ->
        names := List.map (fun (e : E.entry) -> e.name) (E.list_children ""));
    if List.mem name !names || Unix.gettimeofday () > deadline then !names
    else (
      Thread.delay 0.05;
      ask ())
  in
  ask ()

let fresh_window = 1.
let wait_stale () = Thread.delay (fresh_window +. 0.1)

(* The test's directories and the domain's config, before anything boots. *)
let setup () =
  Fs.rm_rf root;
  List.iter
    (fun (var, dir) ->
      let dir = Filename.concat root dir in
      Fs.mkdir_p ~perm:0o700 dir;
      Unix.putenv var dir)
    [("HOME", "home"); ("XDG_DATA_HOME", "data"); ("XDG_CACHE_HOME", "cache")];
  Unix.putenv "TSYNC_CONFIG_JSON"
    (Printf.sprintf
       {|{"name":"phone","domains":[{"name":"docs","symlinks":"skip","versioning":true,
          "extensions":["totp","passwords"],"frontends":["android"],
          "backends":[{"type":"gated","name":"main","role":"main","path":"%s"}]}]}|}
       store_path)
