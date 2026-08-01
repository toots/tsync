(* End-to-end check of the macOS File Provider, against a domain it stages
   itself.

   The checks live in {!E2e}, which knows nothing about File Provider: a frontend
   gives the user a directory, and what is asserted about it is the same on either
   platform. Here is the staging — on macOS, getting a domain registered with the
   system, which only the installed app can do — and the one consistency checker
   macOS has of its own.

   Staged and taken down again:

     - a store daemon, serving a local directory over http-proxy;
     - a domain in the installed app's config pointing at it, registered by
       restarting the app, so a real replica exists;
     - a second client against the same store.

   Needs the app installed ([make -C macos install]). The config it edits is put
   back on the way out, including when a check fails. *)

open E2e

let env = { domain = "tsync-e2e"; port = 8788; secret = "e2e-secret" }

let () =
  Random.self_init ();
  let paths = Runtime.default_paths () in
  let exe = Filename.concat (Sys.getcwd ()) "_build/default/bin/tsync.exe" in
  if not (Sys.file_exists exe) then (
    prerr_endline "no tsync binary; run `dune build bin/tsync.exe`";
    exit 1);
  if not (Sys.file_exists "/Applications/TsyncApp.app") then (
    prerr_endline "TsyncApp is not installed; run `make -C macos install`";
    exit 1);

  let root = scratch_root "tse" in
  let store = Filename.concat root "store" in
  let store_home = Filename.concat root "sh" in
  let client_home = Filename.concat root "ch" in
  List.iter
    (fun d -> sh "mkdir -p %s" (Filename.quote d))
    [store; store_home; client_home];

  let config = paths.Runtime.config_path in
  let backup = config ^ ".e2e-backup" in
  let had_config = Sys.file_exists config in
  if had_config then
    sh "cp %s %s" (Filename.quote config) (Filename.quote backup);

  let store_pid = ref None and client_pid = ref None in
  let restore () =
    Option.iter stop_daemon !client_pid;
    Option.iter stop_daemon !store_pid;
    if had_config then
      sh "mv %s %s" (Filename.quote backup) (Filename.quote config)
    else sh "rm -f %s" (Filename.quote config);
    (* Reconciling on the way back drops the staged domain: the app removes any
       domain the config no longer names. *)
    ignore (Runtime.restart_service ());
    sh "rm -rf %s" (Filename.quote root)
  in
  let finish code =
    restore ();
    exit code
  in

  (try
     Printf.printf "staging in %s\n%!" root;

     (* The store, served over http-proxy. *)
     write_config ~home:store_home ~name:"e2e-store"
       ~domains:
         [
           domain_json ~env
             ~backends:[local_backend ~path:store]
             ~frontends:[proxy_frontend ~env];
         ];
     store_pid := Some (spawn_daemon ~exe ~home:store_home ~label:"store" ());
     wait_until ~timeout:30. ~what:"the store to listen" (fun () ->
         Sys.command
           (Printf.sprintf "curl -sf -o /dev/null http://127.0.0.1:%d/" env.port)
         = 0);

     (* The domain the installed app will register, pointing at that store.
        Whatever else was configured is kept: this machine is somebody's. *)
     let existing =
       if had_config then (
         match member "domains" (Yojson.Safe.from_file backup) with
           | `List l ->
               List.filter (fun d -> str (member "name" d) <> env.domain) l
           | _ -> [])
       else []
     in
     let client_name =
       if had_config then str (member "name" (Yojson.Safe.from_file backup))
       else ""
     in
     write_config ~home:(Sys.getenv "HOME")
       ~name:(if client_name = "" then "e2e" else client_name)
       ~domains:
         (existing
         @ [
             domain_json ~env
               ~backends:[proxy_backend ~env]
               ~frontends:[`String "file_provider"];
           ]);
     if not (Runtime.restart_service ()) then failf "could not restart TsyncApp";

     let mount =
       until ~timeout:60. ~what:"the domain to be registered" (fun () ->
           File_provider.domain_dir ~domain_name:env.domain)
     in
     Printf.printf "domain at %s\n%!" mount;
     wait_until ~timeout:60. ~what:"the daemon socket" (fun () ->
         Sys.file_exists paths.Runtime.socket_path);
     wait_writable ~mount;

     (* The second client, against the same store. *)
     write_config ~home:client_home ~name:"e2e-client"
       ~domains:
         [
           domain_json ~env
             ~backends:[proxy_backend ~env]
             ~frontends:[`String "file_provider"];
         ];
     client_pid := Some (spawn_daemon ~exe ~home:client_home ~label:"client" ());
     let client =
       {
         socket_path = domain_socket ~home:client_home ~domain:env.domain;
         root = client_home;
         env;
       }
     in
     wait_until ~timeout:30. ~what:"the second client to start" (fun () ->
         match items client with _ -> true | exception _ -> false);

     let extra () =
       (* Opening a large file must not pull the whole thing down. The choice is
          made inside the system and both look the same once the read returns, so
          the request the extension makes on the way past is the only
          evidence. *)
       check "reading part of a large file fetches only part of it" (fun () ->
           let name = "big-" ^ string_of_int (Random.bits ()) ^ ".bin" in
           (* Several chunks across several groups at the production chunk size:
              the installed daemon's environment belongs to launchd, so the test
              cannot shrink them the way tests/fetch_range does. *)
           let size = 40 * 1024 * 1024 in
           let contents =
             String.init size (fun i -> Char.chr (i * 7 mod 251))
           in
           (* Created on the far side, so the replica has never held the bytes:
              it is dataless without anything having to evict it. *)
           remote_write client ~parent:"root" ~name contents;
           let path = Filename.concat mount name in
           wait_until ~timeout:120. ~what:(name ^ " to appear in the mount")
             (fun () -> Sys.file_exists path);

           let tap = Ipc_tap.start ~socket_path:paths.Runtime.socket_path in
           Fun.protect
             ~finally:(fun () -> Ipc_tap.stop tap)
             (fun () ->
               let offset = 20 * 1024 * 1024 in
               let got =
                 let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
                 Fun.protect
                   ~finally:(fun () -> Unix.close fd)
                   (fun () ->
                     ignore (Unix.lseek fd offset Unix.SEEK_SET);
                     let buf = Bytes.create 4096 in
                     let n = Unix.read fd buf 0 4096 in
                     Bytes.sub_string buf 0 n)
               in
               if got <> String.sub contents offset 4096 then
                 failf "the bytes read back are not the file's";

               (* A range fetch happening at all is the system taking the
                  partial path; a whole-file fetch is it declining to. *)
               let ranges = Ipc_tap.requests tap "fetch_range" in
               let whole = Ipc_tap.requests tap "ensure_cached" in
               if ranges = [] then
                 failf
                   "no fetch_range: the system did not use partial fetching \
                    (%d whole-file fetches)"
                   (List.length whole);
               if whole <> [] then
                 failf "%d whole-file fetches for a %d-byte read"
                   (List.length whole) 4096;

               (* And the ranges asked for have to be a fraction of the file,
                  or partial fetching is only partial in name. *)
               let asked =
                 List.fold_left
                   (fun acc r ->
                     acc
                     +
                       match Ipc_tap.field "length" r with
                       | `Int n -> n
                       | _ -> 0)
                   0 ranges
               in
               Printf.printf "  %d fetch_range request(s), %d bytes of %d\n%!"
                 (List.length ranges) asked size;
               if asked >= size then failf "fetched %d bytes to read 4096" asked));

       (* Apple's own checker over the replica. Nothing else here would notice
          the system's bookkeeping disagreeing with what it shows. *)
       check "fileproviderctl reports no broken invariants" (fun () ->
           let out = Filename.temp_file "tsync-fpck" ".txt" in
           sh "/usr/bin/fileproviderctl check -a %s > %s 2>&1"
             (Filename.quote mount) (Filename.quote out);
           let body = read_file out in
           Sys.remove out;
           let broken =
             String.split_on_char '\n' body
             |> List.filter (fun l ->
                 contains (String.lowercase_ascii l) "broken"
                 && not (contains l "0 broken"))
           in
           if broken <> [] then failf "%s" (String.concat "; " broken))
     in
     run ~env ~mount ~store ~client ~extra
   with
    | Failed msg ->
        Printf.eprintf "staging failed: %s\n" msg;
        report_daemon_logs ();
        finish 1
    | exn ->
        Printf.eprintf "staging failed: %s\n" (Printexc.to_string exn);
        report_daemon_logs ();
        finish 1);

  finish (summary ())
