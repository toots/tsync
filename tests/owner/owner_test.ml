open Tsync_core
open Tsync_ipc
open Tsync_owner

let p fmt = Printf.printf (fmt ^^ "\n%!")

let root =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "tsync-owner-%d" (Unix.getpid ()))

let home = Filename.concat root "home"

let () =
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (Filename.concat root d))
    ["home"; "data"; "cache"];
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_DATA_HOME" (Filename.concat root "data");
  Unix.putenv "XDG_CACHE_HOME" (Filename.concat root "cache")

let socket = Filename.concat root "data/tsync/test.sock"

let config =
  Tsync_config.Config.of_string
    (Printf.sprintf
       {|{"name":"test","domains":[
  {"name":"docs","symlinks":"keep","versioning":true,"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"main","path":"%s/store"}]},
  {"name":"ro","symlinks":"keep","versioning":true,"frontends":["http-proxy"],
   "backends":[{"type":"local","name":"main","role":"readOnly","path":"%s/store"}]}]}|}
       root root)

(* Folder ids ([<12 hex>-<counter>]) and content hashes (16 hex digits) are
   shown as stable placeholders. *)
let ids = Hashtbl.create 16

let placeholder id =
  match Hashtbl.find_opt ids id with
    | Some k -> k
    | None ->
        let k = Printf.sprintf "<id%d>" (Hashtbl.length ids + 1) in
        Hashtbl.replace ids id k;
        k

let scrub_string s =
  let b = Buffer.create (String.length s) in
  let hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') in
  let n = String.length s in
  let run i =
    let j = ref i in
    while !j < n && hex s.[!j] do
      incr j
    done;
    !j
  in
  let rec go i =
    if i < n then
      if hex s.[i] && (i = 0 || not (hex s.[i - 1])) then (
        let j = run i in
        let j =
          if j - i = 12 && j + 1 < n && s.[j] = '-' && hex s.[j + 1] then
            run (j + 1)
          else j
        in
        let token = String.sub s i (j - i) in
        Buffer.add_string b
          (if j - i = 16 || String.contains token '-' then placeholder token
           else token);
        go j)
      else (
        Buffer.add_char b s.[i];
        go (i + 1))
  in
  go 0;
  Buffer.contents b

let rec scrub = function
  | `Assoc l ->
      `Assoc
        (List.map
           (fun (k, v) ->
             match (k, v) with
               | ("mtime" | "pinnedUntil"), `Float _ -> (k, `String "<t>")
               | ("localPath" | "error"), `String s ->
                   let r = String.length root in
                   let s =
                     if String.length s >= r && String.sub s 0 r = root then
                       "<root>" ^ String.sub s r (String.length s - r)
                     else s
                   in
                   (k, `String (scrub_string s))
               | _ -> (k, scrub v))
           l)
  | `List l -> `List (List.map scrub l)
  | `String s -> `String (scrub_string s)
  | j -> j

let ask ?(domain = Some "docs") fields =
  let req =
    `Assoc
      ((match domain with Some d -> [("domain", `String d)] | None -> [])
      @ List.map (fun (k, v) -> (k, `String v)) fields)
  in
  Ipc.call socket req

let show label r = p "%-34s %s" label (Yojson.Safe.to_string (scrub r))
let get r k = Option.get (Ipc.field r k)

let item_ref r =
  match r with
    | `Assoc l -> (
        match List.assoc_opt "item" l with
          | Some i -> Option.get (Ipc.field i "ref")
          | None -> get r "ref")
    | _ -> assert false

let staging name body =
  let path = Filename.concat home name in
  Fs.write_file_for_test path body;
  path

let rec wait_serving n =
  match Ipc.call socket (`Assoc [("action", `String "ping")]) with
    | _ -> ()
    | exception _ when n > 0 ->
        Rt.sleep 0.05;
        wait_serving (n - 1)

let () =
  Owner.stop_on_signals ();
  Rt.run_sync (fun () ->
      let owner =
        Rt.async (fun () ->
            Owner.run ~socket config config.Tsync_config.Config.domains)
      in
      wait_serving 100;
      p "== ownership";
      (match
         Owner.acquire ~role:"command" ~what:"test" (Domain_name.v "docs")
       with
        | Ok _ -> p "second owner acquired the lock"
        | Error (Some h) ->
            p "held by role=%s what=%s socket=%b" h.role h.what
              (h.socket = Some socket)
        | Error None -> p "held, no record");
      p "== rows and mutations";
      show "stat root" (ask [("action", "stat"); ("ref", "root")]);
      let a = ask [("action", "mkdir"); ("parentRef", "root"); ("name", "a")] in
      show "mkdir a" a;
      let a_ref = item_ref a in
      show "mkdir a again"
        (ask [("action", "mkdir"); ("parentRef", "root"); ("name", "a")]);
      show "mkdir a exclusive"
        (Ipc.call socket
           (`Assoc
              [
                ("domain", `String "docs");
                ("action", `String "mkdir");
                ("parentRef", `String "root");
                ("name", `String "a");
                ("exclusive", `Bool true);
              ]));
      let w =
        ask
          [
            ("action", "write");
            ("parentRef", a_ref);
            ("name", "f.txt");
            ("staging", staging "s1" "hello world");
          ]
      in
      show "write a/f.txt" w;
      let f_ref = item_ref w in
      show "stat by rel" (ask [("action", "stat"); ("rel", "a/f.txt")]);
      show "list_dir root" (ask [("action", "list_dir"); ("ref", "root")]);
      show "list_dir a" (ask [("action", "list_dir"); ("ref", a_ref)]);
      show "staging outside the roots"
        (ask
           [
             ("action", "write");
             ("parentRef", a_ref);
             ("name", "g.txt");
             ("staging", "/etc/hostname");
           ]);
      let dest = Filename.concat home "out.txt" in
      show "ensure_cached"
        (ask [("action", "ensure_cached"); ("ref", f_ref); ("dest", dest)]);
      p "%-34s %S" "  content" (Fs.read_file dest);
      show "ensure_cached onto a file"
        (ask [("action", "ensure_cached"); ("ref", f_ref); ("dest", dest)]);
      show "rename to g.txt"
        (ask
           [
             ("action", "rename");
             ("ref", f_ref);
             ("parentRef", a_ref);
             ("name", "g.txt");
           ]);
      show "stat the old ref" (ask [("action", "stat"); ("ref", f_ref)]);
      show "delete a folder" (ask [("action", "delete"); ("ref", a_ref)]);
      show "rmdir a" (ask [("action", "rmdir"); ("ref", a_ref)]);
      show "list_dir root" (ask [("action", "list_dir"); ("ref", "root")]);
      p "== refusals";
      show "malformed ref" (ask [("action", "stat"); ("ref", "x:1")]);
      show "storage key" (ask [("action", "stat"); ("ref", "tsync/docs/x")]);
      show "unknown action" (ask [("action", "frobnicate")]);
      show "read-only domain"
        (ask ~domain:(Some "ro")
           [("action", "mkdir"); ("parentRef", "root"); ("name", "x")]);
      show "no domain on a shared socket"
        (ask ~domain:None [("action", "stat")]);
      show "a domain not served"
        (ask ~domain:(Some "nope") [("action", "stat")]);
      show "pause" (ask [("action", "pause"); ("arg", "on")]);
      show "sync while paused" (ask [("action", "sync")]);
      show "resume" (ask [("action", "pause"); ("arg", "off")]);
      p "== events";
      let c = Ipc.Client.connect socket in
      show "subscribe"
        (Ipc.Client.request c
           (`Assoc [("action", `String "subscribe"); ("domain", `String "docs")]));
      show "first event" (Option.get (Ipc.Client.next ~timeout:2. c));
      show "notify_reset" (ask [("action", "notify_reset")]);
      show "next event" (Option.get (Ipc.Client.next ~timeout:2. c));
      p "== jobs";
      let reports = ref [] and rm = Mutex.create () in
      let supervisor =
        Ipc.serve ~path:(Tsync_config.Paths.supervisor_socket ()) (fun req ->
            (match
               ( Ipc.field req "action",
                 Ipc.field req "kind",
                 Ipc.field req "state" )
             with
              | Some "report", Some kind, Some state ->
                  Mutex.protect rm (fun () ->
                      reports := (kind, state) :: !reports)
              | _ -> ());
            Ipc.Reply (Ipc.ok []))
      in
      let job ?(narrate = false) j =
        `Assoc
          [
            ("action", `String "job");
            ("domain", `String "docs");
            ("job", Jobs.to_yojson j);
            ("narrate", `Bool narrate);
          ]
      and cancel id =
        Ipc.call socket
          (`Assoc
             [
               ("action", `String "cancel");
               ("domain", `String "docs");
               ("job", `Int id);
             ])
      and gc ?(apply = false) ?(abort = false) () =
        Jobs.Gc { apply; verify = false; abort; budget = None }
      in
      let narrated = ref 0 and progressed = ref 0 in
      let line l =
        match Ipc.field l "stream" with
          | Some "narrate" -> incr narrated
          | Some "progress" ->
              if Ipc.field l "text" <> Some "" then incr progressed
          | _ -> show "  line" l
      in
      show "sync --full, narrated"
        (Ipc.call_stream socket
           (job ~narrate:true (Sync { full = true }))
           ~on_line:line);
      p "  progress streamed: %b" (!progressed > 0);
      show "gc dry run, narrated"
        (Ipc.call_stream socket (job ~narrate:true (gc ())) ~on_line:line);
      p "  narration streamed: %b, progress streamed: %b" (!narrated > 0)
        (!progressed > 0);
      let spaces =
        Tsync_store.Chunk_spaces.create (Filename.concat root "store")
      in
      let c = Ipc.Client.connect socket in
      let id =
        Tsync_store.Chunk_spaces.with_publish_lock spaces (Domain_name.v "docs")
          ~exclusive:false (fun () ->
            let started = Ipc.Client.request c (job (gc ~apply:true ())) in
            show "gc --apply, held at opening" started;
            show "expire meanwhile"
              (Ipc.call socket (job (Expire { apply = false; cutoff = 0. })));
            let id = Yojson.Safe.Util.(to_int (member "job" started)) in
            show "cancel it" (cancel id);
            id)
      in
      let rec rest () =
        match Ipc.Client.next ~timeout:60. c with
          | Some l ->
              line l;
              if Ipc.field l "stream" <> None then rest ()
          | None -> ()
      in
      rest ();
      Ipc.Client.close c;
      show "cancel once it ended" (cancel id);
      show "gc --abort"
        (Ipc.call_stream socket (job (gc ~abort:true ())) ~on_line:line);
      Ipc.close supervisor;
      p "reports the supervisor got, in order:";
      List.iter
        (fun (kind, state) -> p "  %s: %s" kind state)
        (List.rev !reports);
      p "== stop";
      show "stop" (ask [("action", "stop")]);
      p "exit status %d" (Rt.Promise.await owner);
      p "socket gone: %b" (not (Sys.file_exists socket)))
