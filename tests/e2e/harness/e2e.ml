(* The part of an end-to-end check that does not depend on how the domain is
   presented.

   A frontend gives the user a directory, and what is asserted about it holds
   whether that is a File Provider replica or a FUSE mount: work done in it
   reaches the store, work done by another client reaches it, and nothing is left
   behind. Each platform supplies only the staging and its own consistency
   checker.

   Everything waited on crosses a process boundary, so nothing is sampled once —
   see {!until}. *)

exception Failed of string

let failf fmt = Printf.ksprintf (fun s -> raise (Failed s)) fmt
let sh fmt = Printf.ksprintf (fun cmd -> ignore (Sys.command cmd)) fmt

(* Generous: the change poller ticks every two seconds and the presenting layer
   schedules work of its own on top. *)
let settle = 30.

type env = { domain : string; port : int; secret : string }

let results : (string * string option) list ref = ref []

let check name f =
  match f () with
    | () ->
        results := (name, None) :: !results;
        Printf.printf "  ok   %s\n%!" name
    | exception Failed msg ->
        results := (name, Some msg) :: !results;
        Printf.printf "  FAIL %s\n         %s\n%!" name msg
    | exception exn ->
        let msg = Printexc.to_string exn in
        results := (name, Some msg) :: !results;
        Printf.printf "  FAIL %s\n         %s\n%!" name msg

(* Exit code, and the tally. *)
let summary () =
  let all = List.rev !results in
  let failed = List.filter (fun (_, e) -> e <> None) all in
  Printf.printf "\n%d/%d checks passed\n"
    (List.length all - List.length failed)
    (List.length all);
  if failed = [] then 0 else 1

let until ?(timeout = settle) ~what f =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    match f () with
      | Some v -> v
      | None ->
          if Unix.gettimeofday () > deadline then
            failf "timed out after %.0fs waiting for %s" timeout what
          else (
            Unix.sleepf 0.25;
            loop ())
  in
  loop ()

let wait_until ?timeout ~what f =
  until ?timeout ~what (fun () -> if f () then Some () else None)

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let entries dir =
  match Sys.readdir dir with
    | exception _ -> []
    | names ->
        List.sort compare
          (List.filter
             (fun n -> String.length n > 0 && n.[0] <> '.')
             (Array.to_list names))

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i =
    i + n <= h && (String.sub haystack i n = needle || go (i + 1))
  in
  n = 0 || go 0

let rec all_files dir =
  match Sys.readdir dir with
    | exception _ -> []
    | names ->
        List.concat_map
          (fun n ->
            let p = Filename.concat dir n in
            match Sys.is_directory p with
              | true -> all_files p
              | false -> [p]
              (* Listed by readdir and gone by the time it was stat'd. Kept as
                 a file rather than dropped: over a mount that is exactly the
                 defect worth reporting -- a name `ls` shows and nothing can
                 open -- and a caller that reads it will mark it unreadable and
                 say so. Dropping it here would delete the evidence and leave a
                 walk that raises mid-directory, which is how it surfaced: as
                 an abort naming a path, with nothing to say about it. *)
              | exception _ -> [p])
          (Array.to_list names)

(* Live manifests and folder markers. The trash namespace is left out on
   purpose: a removed directory is detached there and reclaimed later by expire,
   so finding one is not a leak. *)
let manifests ~env ~store =
  let prefix =
    Filename.concat store (Printf.sprintf "tsync/%s/manifests/" env.domain)
  in
  all_files store
  |> List.filter (fun p -> String.starts_with ~prefix p)
  |> List.filter (fun p -> not (contains p ".tsync-trash/"))

let member k = function
  | `Assoc l -> ( match List.assoc_opt k l with Some v -> v | None -> `Null)
  | _ -> `Null

let str j = match j with `String s -> s | _ -> ""
let int_of j = match j with `Int n -> n | _ -> -1

type client = { socket_path : string; root : string; env : env }

let ipc ?(expect_ok = true) client fields =
  let request =
    `Assoc (("domain", `String client.env.domain) :: fields)
    |> Yojson.Safe.to_string
  in
  let json =
    Yojson.Safe.from_string (Ipc.send ~socket_path:client.socket_path request)
  in
  if expect_ok && member "ok" json <> `Bool true then
    failf "%s: %s (%s)"
      (match List.assoc_opt "action" fields with
        | Some (`String a) -> a
        | _ -> "request")
      (str (member "error" json))
      (str (member "code" json));
  json

let items ?(ref_ = "root") client =
  match
    member "items"
      (ipc client [("action", `String "list_dir"); ("ref", `String ref_)])
  with
    | `List l -> l
    | _ -> []

let names ?ref_ client =
  List.sort compare
    (List.map (fun i -> str (member "name" i)) (items ?ref_ client))

let item_named ?ref_ client name =
  List.find_opt (fun i -> str (member "name" i) = name) (items ?ref_ client)

let stage_file client contents =
  let path =
    Filename.concat client.root (Printf.sprintf "stage-%d" (Random.bits ()))
  in
  write_file path contents;
  path

let remote_write client ~parent ~name contents =
  ignore
    (ipc client
       [
         ("action", `String "write");
         ("parentRef", `String parent);
         ("name", `String name);
         ("staging", `String (stage_file client contents));
       ])

let remote_mkdir client ~parent ~name =
  ignore
    (ipc client
       [
         ("action", `String "mkdir");
         ("parentRef", `String parent);
         ("name", `String name);
       ])

let remote_remove client ~ref_ ~is_dir =
  ignore
    (ipc client
       [
         ("action", `String (if is_dir then "rmdir" else "delete"));
         ("ref", `String ref_);
       ])

let remote_rename client ~ref_ ~parent ~name =
  ignore
    (ipc client
       [
         ("action", `String "rename");
         ("ref", `String ref_);
         ("parentRef", `String parent);
         ("name", `String name);
       ])

(* Asked of {!Runtime} rather than worked out here: the platforms disagree about
   all of it. The spawned daemon inherits everything but HOME, so it resolves the
   same paths. *)
let paths_for ~home =
  let saved = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" home;
  let paths = Runtime.default_paths () in
  Option.iter (Unix.putenv "HOME") saved;
  paths

let config_path home = (paths_for ~home).Runtime.config_path

(* macOS serves every domain on one socket; a FUSE domain gets its own, because
   each runs in its own process. *)
let domain_socket ~home ~domain =
  Runtime.domain_socket_path (paths_for ~home) domain

let local_backend ~path =
  `Assoc
    [
      ("name", `String "store");
      ("type", `String "local");
      ("role", `String "main");
      ("path", `String path);
    ]

let proxy_backend ~env =
  `Assoc
    [
      ("name", `String "proxy");
      ("type", `String "http-proxy");
      ("role", `String "main");
      ("url", `String (Printf.sprintf "http://127.0.0.1:%d" env.port));
      ("secret", `String env.secret);
    ]

let proxy_frontend ~env =
  `Assoc
    [
      ("type", `String "http-proxy");
      ("port", `Int env.port);
      ("secret", `String env.secret);
      ("shares", `Bool true);
      ("readOnly", `Bool false);
    ]

let domain_json ~env ~backends ~frontends =
  `Assoc
    [
      ("name", `String env.domain);
      ("versioning", `Bool false);
      ("symlinks", `String "keep");
      ("readOnly", `Bool false);
      ("backends", `List backends);
      ("frontends", `List frontends);
    ]

let write_config ~home ~name ~domains =
  let path = config_path home in
  sh "mkdir -p %s" (Filename.quote (Filename.dirname path));
  write_file path
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("name", `String name);
            ("maxUploads", `Int 4);
            ("maxDownloads", `Int 8);
            ("domains", `List domains);
          ]))

(* Every path derives from HOME, so redirecting it keeps a staged client off the
   real cache, journal and socket — and off the shared client id, without which
   two daemons each skip the other's journal entries as their own. *)
(* Kept rather than discarded: a daemon dying at startup otherwise shows up only
   as whatever was waited for never happening, and "timed out after 60s" says
   nothing about why. *)
let daemon_logs : (string * string) list ref = ref []

let spawn_daemon ?(args = []) ~exe ~home ~label () =
  let env =
    Array.append
      (Array.of_list
         (List.filter
            (fun kv -> not (String.starts_with ~prefix:"HOME=" kv))
            (Array.to_list (Unix.environment ()))))
      [| "HOME=" ^ home |]
  in
  let log = Filename.concat home (label ^ ".log") in
  daemon_logs := (label, log) :: !daemon_logs;
  let fd =
    Unix.openfile log [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600
  in
  let argv = Array.of_list (exe :: "start" :: args) in
  let pid = Unix.create_process_env exe argv env Unix.stdin fd fd in
  Unix.close fd;
  pid

(* Printed when staging fails, which is the only time anyone wants it. *)
let report_daemon_logs () =
  List.iter
    (fun (label, path) ->
      match read_file path with
        | exception _ -> Printf.eprintf "\n--- %s: no log\n" label
        | "" -> Printf.eprintf "\n--- %s: said nothing\n" label
        | body ->
            let lines = String.split_on_char '\n' body in
            let n = List.length lines in
            let tail =
              if n <= 25 then lines
              else List.filteri (fun i _ -> i >= n - 25) lines
            in
            Printf.eprintf "\n--- %s ---\n%s\n" label (String.concat "\n" tail))
    (List.rev !daemon_logs)

let stop_daemon pid =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  let deadline = Unix.gettimeofday () +. 20. in
  let rec wait () =
    match Unix.waitpid [Unix.WNOHANG] pid with
      | 0, _ when Unix.gettimeofday () < deadline ->
          Unix.sleepf 0.2;
          wait ()
      | 0, _ -> ( try Unix.kill pid Sys.sigkill with _ -> ())
      | _ -> ()
      | exception _ -> ()
  in
  wait ()

(* Short on purpose: a unix socket path is capped at 104 bytes and the daemon
   puts its socket several directories below HOME. *)
let scratch_root prefix =
  Printf.sprintf "/tmp/%s-%06x" prefix (Random.bits () land 0xffffff)

(* A directory existing does not mean the frontend behind it will take a write:
   on macOS the folder appears as soon as the domain is registered, while the
   system is still bringing the provider up, and the first write times out. *)
let wait_writable ~mount =
  let probe = Filename.concat mount ".e2e-probe" in
  wait_until ~timeout:120. ~what:"the mount to accept a write" (fun () ->
      match
        write_file probe "probe";
        Sys.remove probe
      with
        | () -> true
        | exception _ ->
            (try Sys.remove probe with _ -> ());
            false)

(* [mount] is the directory the frontend gives the user. [client] is a second,
   independent client against the same store. [extra] runs before the tidy-up,
   for whatever consistency checker the platform has. *)
let run ~env ~mount ~store ~client ~extra =
  let tag = Printf.sprintf "%06x" (Random.bits () land 0xffffff) in
  let path name = Filename.concat mount name in
  let mounted () = entries mount in

  check "a file created by the user reaches the store" (fun () ->
      let name = "created-" ^ tag ^ ".txt" in
      write_file (path name) "hello from the mount";
      let item =
        until ~what:(name ^ " to reach the store") (fun () ->
            item_named client name)
      in
      if int_of (member "size" item) <> 20 then
        failf "size %d, expected 20" (int_of (member "size" item));
      if str (member "kind" item) <> "file" then
        failf "kind %s" (str (member "kind" item)));

  check "editing a file is published as a new version" (fun () ->
      let name = "edited-" ^ tag ^ ".txt" in
      write_file (path name) "first";
      let before =
        until ~what:(name ^ " to appear") (fun () -> item_named client name)
      in
      let etag = str (member "etag" before) in
      write_file (path name) "second version, longer";
      let after =
        until ~what:(name ^ " to be updated") (fun () ->
            match item_named client name with
              | Some i when str (member "etag" i) <> etag -> Some i
              | _ -> None)
      in
      if int_of (member "size" after) <> 22 then
        failf "size %d after edit, expected 22" (int_of (member "size" after)));

  check "copying a file within the domain" (fun () ->
      let src = "copysrc-" ^ tag ^ ".txt" and dst = "copydst-" ^ tag ^ ".txt" in
      write_file (path src) "copy me please";
      ignore
        (until ~what:(src ^ " to appear") (fun () -> item_named client src));
      sh "cp %s %s" (Filename.quote (path src)) (Filename.quote (path dst));
      let item =
        until ~what:(dst ^ " to appear") (fun () -> item_named client dst)
      in
      if int_of (member "size" item) <> 14 then
        failf "size %d, expected 14" (int_of (member "size" item));
      if read_file (path dst) <> "copy me please" then
        failf "the copy does not read back");

  check "a folder and a file inside it" (fun () ->
      let folder = "dir-" ^ tag in
      Unix.mkdir (path folder) 0o755;
      let entry =
        until ~what:(folder ^ " to appear") (fun () -> item_named client folder)
      in
      if str (member "kind" entry) <> "dir" then
        failf "kind %s" (str (member "kind" entry));
      write_file (Filename.concat (path folder) "inside.txt") "nested";
      let ref_ = str (member "ref" entry) in
      let child =
        until ~what:"the nested file to appear" (fun () ->
            item_named ~ref_ client "inside.txt")
      in
      if str (member "parentRef" child) <> ref_ then
        failf "parent %s <> %s" (str (member "parentRef" child)) ref_);

  check "deleting a file leaves no manifest behind" (fun () ->
      let name = "doomed-" ^ tag ^ ".txt" in
      write_file (path name) "delete me";
      let item =
        until ~what:(name ^ " to appear") (fun () -> item_named client name)
      in
      let ref_ = str (member "ref" item) in
      let before = List.length (manifests ~env ~store) in
      Sys.remove (path name);
      wait_until ~what:(name ^ " to leave the store") (fun () ->
          item_named client name = None);
      if List.length (manifests ~env ~store) >= before then
        failf "no manifest was removed (%d before, %d after)" before
          (List.length (manifests ~env ~store));
      (* And the daemon agrees it is gone, rather than answering from a stale
         local mirror. *)
      let response =
        ipc ~expect_ok:false client
          [("action", `String "stat"); ("ref", `String ref_)]
      in
      if str (member "code" response) <> "not_found" then
        failf "stat says %S, expected not_found" (str (member "code" response)));

  (* The other direction: everything above could pass with the daemon unable to
     tell the presenting layer anything. *)
  check "a file created by another client appears" (fun () ->
      let name = "remote-" ^ tag ^ ".txt" in
      remote_write client ~parent:"root" ~name "made by the other client";
      wait_until ~what:(name ^ " to appear") (fun () ->
          List.mem name (mounted ()));
      if read_file (path name) <> "made by the other client" then
        failf "content does not match");

  check "an edit by another client arrives" (fun () ->
      let name = "remote-edit-" ^ tag ^ ".txt" in
      remote_write client ~parent:"root" ~name "before";
      wait_until ~what:(name ^ " to appear") (fun () ->
          List.mem name (mounted ()));
      if read_file (path name) <> "before" then failf "initial content wrong";
      remote_write client ~parent:"root" ~name "after, which is longer";
      wait_until ~what:"the remote edit to arrive" (fun () ->
          read_file (path name) = "after, which is longer"));

  check "a delete by another client is reflected" (fun () ->
      let name = "remote-doomed-" ^ tag ^ ".txt" in
      remote_write client ~parent:"root" ~name "temporary";
      wait_until ~what:(name ^ " to appear") (fun () ->
          List.mem name (mounted ()));
      let item =
        until ~what:(name ^ " in the store") (fun () -> item_named client name)
      in
      remote_remove client ~ref_:(str (member "ref" item)) ~is_dir:false;
      wait_until ~what:(name ^ " to disappear") (fun () ->
          not (List.mem name (mounted ()))));

  check "a folder created and removed by another client" (fun () ->
      let folder = "remote-dir-" ^ tag in
      remote_mkdir client ~parent:"root" ~name:folder;
      wait_until ~what:(folder ^ " to appear") (fun () ->
          List.mem folder (mounted ()));
      if not (Sys.is_directory (path folder)) then
        failf "it did not arrive as a directory";
      let entry =
        until ~what:(folder ^ " in the store") (fun () ->
            item_named client folder)
      in
      remote_remove client ~ref_:(str (member "ref" entry)) ~is_dir:true;
      wait_until ~what:(folder ^ " to disappear") (fun () ->
          not (List.mem folder (mounted ()))));

  (* A renamed folder keeps its reference, or everything under it is
     re-identified without the presenting layer being told. *)
  check "a folder renamed remotely keeps its identity" (fun () ->
      let before = "ren-before-" ^ tag and after = "ren-after-" ^ tag in
      remote_mkdir client ~parent:"root" ~name:before;
      let entry =
        until ~what:(before ^ " to appear") (fun () -> item_named client before)
      in
      wait_until ~what:(before ^ " to arrive") (fun () ->
          List.mem before (mounted ()));
      let ref_ = str (member "ref" entry) in
      remote_rename client ~ref_ ~parent:"root" ~name:after;
      let renamed =
        until ~what:(after ^ " to appear") (fun () -> item_named client after)
      in
      if str (member "ref" renamed) <> ref_ then
        failf "the folder changed identity: %s -> %s" ref_
          (str (member "ref" renamed));
      wait_until ~what:"the rename to arrive" (fun () ->
          List.mem after (mounted ()) && not (List.mem before (mounted ()))));

  check "sharing a file yields a URL that serves it" (fun () ->
      let name = "shared-" ^ tag ^ ".txt" in
      write_file (path name) "shareable content";
      let item =
        until ~what:(name ^ " to appear") (fun () -> item_named client name)
      in
      let response =
        ipc client
          [
            ("action", `String "share");
            ("ref", `String (str (member "ref" item)));
          ]
      in
      match member "url" response with
        | `String url ->
            let out = Filename.temp_file "tsync-share" ".txt" in
            sh "curl -sf %s -o %s"
              (Filename.quote (url ^ "/download"))
              (Filename.quote out);
            let body = read_file out in
            Sys.remove out;
            if body <> "shareable content" then failf "the URL served %S" body
        | _ -> failf "no URL in the response");

  (* The form a file manager sends: it holds a path, and stripping the mount the
     daemon just reported leaves exactly this. *)
  check "sharing by relative path yields a URL that serves it" (fun () ->
      let name = "shared-rel-" ^ tag ^ ".txt" in
      write_file (path name) "shareable by path";
      ignore
        (until ~what:(name ^ " to appear") (fun () -> item_named client name));
      let response =
        ipc client [("action", `String "share"); ("rel", `String name)]
      in
      match member "url" response with
        | `String url ->
            let out = Filename.temp_file "tsync-share-rel" ".txt" in
            sh "curl -sf %s -o %s"
              (Filename.quote (url ^ "/download"))
              (Filename.quote out);
            let body = read_file out in
            Sys.remove out;
            if body <> "shareable by path" then failf "the URL served %S" body
        | _ -> failf "no URL in the response");

  (* Waited for, not sampled: the second client builds its mirror by replaying
     the journal, so comparing straight away races its catch-up. *)
  check "the mount and the store agree on what exists" (fun () ->
      try
        wait_until ~what:"the mount and the store to agree" (fun () ->
            mounted () = names client)
      with Failed _ ->
        failf "mount has %s, store has %s"
          (String.concat ", " (mounted ()))
          (String.concat ", " (names client)));

  extra ();

  (* Removed through the mount rather than the daemon's socket: an operation a
     daemon performs itself is journalled as its own and filtered out of its own
     change feed, so the presenting layer would never hear about it. *)
  check "everything it made is cleaned up again" (fun () ->
      List.iter
        (fun name -> sh "rm -rf %s" (Filename.quote (path name)))
        (mounted ());
      wait_until ~what:"the mount to empty" (fun () -> mounted () = []);
      wait_until ~what:"the store to empty" (fun () -> names client = []))
