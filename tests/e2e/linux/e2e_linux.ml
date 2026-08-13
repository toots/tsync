(* End-to-end check of the Linux FUSE mount, against a domain it stages itself.

   The checks live in {!E2e} and are the same ones the macOS program runs: a
   frontend gives the user a directory, and what is asserted about it does not
   depend on which frontend produced it. Here is the staging.

   Simpler than macOS, since nothing has to be registered with the system: the
   mount is the frontend. Staged and taken down again:

     - a store daemon, serving a local directory over http-proxy;
     - a client that mounts it with FUSE, which is the directory under test;
     - a second client against the same store, with its own cache, journal cursor
       and client id.

   Nothing outside the scratch directory is touched: no shared config, no service
   restart, no root. Needs fuse3 and permission to mount. *)

open E2e

let env = { domain = "tsync-e2e"; port = 8788; secret = "e2e-secret" }

(* The mount has to be gone before the directory holding it can be: a daemon that
   already exited leaves it behind as an unreachable stub. *)
let unmount mount =
  sh
    "fusermount3 -u %s 2>/dev/null || fusermount -u %s 2>/dev/null || umount \
     %s 2>/dev/null"
    (Filename.quote mount) (Filename.quote mount) (Filename.quote mount)

let () =
  Random.self_init ();
  let exe = Filename.concat (Sys.getcwd ()) "_build/default/bin/tsync.exe" in
  if not (Sys.file_exists exe) then (
    prerr_endline "no tsync binary; run `dune build bin/tsync.exe`";
    exit 1);

  let root = scratch_root "tse" in
  let store = Filename.concat root "store" in
  let store_home = Filename.concat root "sh" in
  let mount_home = Filename.concat root "mh" in
  let client_home = Filename.concat root "ch" in
  let mount = Filename.concat root "mnt" in
  (* The second client also gets a mount: FUSE is the only frontend on this
     platform that serves an IPC socket, and the socket is what drives it. *)
  let mount_b = Filename.concat root "mnt-b" in
  List.iter
    (fun d -> sh "mkdir -p %s" (Filename.quote d))
    [store; store_home; mount_home; client_home; mount; mount_b];

  let store_pid = ref None and mount_pid = ref None and client_pid = ref None in
  let restore () =
    Option.iter stop_daemon !client_pid;
    Option.iter stop_daemon !mount_pid;
    unmount mount;
    unmount (Filename.concat root "mnt-b");
    Option.iter stop_daemon !store_pid;
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

     (* The mount under test. One domain, so --mount names where it goes. *)
     write_config ~home:mount_home ~name:"e2e-mount"
       ~domains:
         [
           domain_json ~env
             ~backends:[proxy_backend ~env]
             ~frontends:[`String "fuse"];
         ];
     mount_pid :=
       Some
         (spawn_daemon ~args:["--mount"; mount] ~exe ~home:mount_home
            ~label:"mount" ());
     (* Mounted, not merely started: until FUSE takes the directory over, reads
        and writes go to the empty directory underneath and every check passes
        against nothing. *)
     wait_until ~timeout:60. ~what:"the filesystem to be mounted" (fun () ->
         Sys.command (Printf.sprintf "mountpoint -q %s" (Filename.quote mount))
         = 0);
     wait_writable ~mount;

     (* The second client, against the same store. It serves IPC without
        presenting anything, which is all this needs of it. *)
     write_config ~home:client_home ~name:"e2e-client"
       ~domains:
         [
           domain_json ~env
             ~backends:[proxy_backend ~env]
             ~frontends:[`String "fuse"];
         ];
     client_pid :=
       Some
         (spawn_daemon ~args:["--mount"; mount_b] ~exe ~home:client_home
            ~label:"client" ());
     let client =
       {
         socket_path = domain_socket ~home:client_home ~domain:env.domain;
         root = client_home;
         env;
       }
     in
     wait_until ~timeout:60. ~what:"the second client to start" (fun () ->
         match items client with _ -> true | exception _ -> false);

     (* Nothing on Linux plays the part fileproviderctl does on macOS; the
        mount's own consistency is what the checks above already assert. *)
     run ~env ~mount ~store ~client ~extra:(fun () ->
         (* A path names its domain, and on Linux each domain binds its own
            socket -- the shared one macOS uses is bound by nothing here. Driven
            through the CLI because the resolution is the CLI's: the daemon
            never sees a request that failed to reach it. *)
         check "a path-based command finds its domain's socket" (fun () ->
             let target = Filename.concat mount "evict-me.txt" in
             write_file target "evict me";
             let out = Filename.concat root "evict.out" in
             let status =
               Sys.command
                 (Printf.sprintf "HOME=%s %s evict %s >%s 2>&1"
                    (Filename.quote mount_home)
                    (Filename.quote exe) (Filename.quote target)
                    (Filename.quote out))
             in
             let said = read_file out in
             if status <> 0 then failf "exited %d: %s" status said;
             if not (String.starts_with ~prefix:"Evicted:" said) then
               failf "did not evict: %s" said));

     (* Last, because it takes the mount down. A reader holding a descriptor open
        must not keep the daemon from stopping: a clean unmount refuses while the
        mount is busy, and the FUSE session outlives the mount point anyway for as
        long as that descriptor is held, so a daemon that waits on its own FUSE
        loop waits on a reader who need never let go. That is a stop timeout per
        restart on any machine where a media server reads the mount. *)
     check "the mount stops while a file is held open" (fun () ->
         match !mount_pid with
           | None -> failf "no mount daemon to stop"
           | Some pid ->
               let probe = Filename.concat mount ".e2e-busy" in
               write_file probe "held";
               let held = open_in_bin probe in
               let started = Unix.gettimeofday () in
               let elapsed () = Unix.gettimeofday () -. started in
               (try Unix.kill pid Sys.sigterm with _ -> ());
               let rec wait () =
                 match Unix.waitpid [Unix.WNOHANG] pid with
                   | 0, _ when elapsed () < 20. ->
                       Unix.sleepf 0.2;
                       wait ()
                   | 0, _ -> None
                   | _, status -> Some status
                   (* Already reaped: it stopped. *)
                   | exception _ -> Some (Unix.WEXITED 0)
               in
               let status = wait () in
               let took = elapsed () in
               close_in_noerr held;
               (* Reaped here, so the teardown must not wait on it again. *)
               mount_pid := None;
               (match status with
                 | None ->
                     failf "still running %.0fs after SIGTERM with a file open"
                       took
                 | Some (Unix.WSIGNALED n) ->
                     failf "killed by signal %d rather than stopping on its own"
                       n
                 | Some _ -> ());
               if took > 10. then
                 failf "took %.1fs to stop with a file open" took)
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
