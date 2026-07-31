(* End-to-end check of the Linux FUSE mount, against a domain it stages itself.

   The checks live in {!E2e} and are the same ones the macOS program runs: a
   frontend gives the user a directory, and what is asserted about that directory
   does not depend on which frontend produced it. What is here is the staging.

   Simpler than macOS, because nothing has to be registered with the system —
   the mount is the frontend. Staged and taken down again:

     - a store daemon, serving a local directory over http-proxy;
     - a client that mounts it with FUSE, which is the directory under test;
     - a second client against the same store, with its own cache, journal cursor
       and client id.

   Nothing outside the scratch directory is touched: no shared config, no service
   restart, no root. Needs fuse3 and permission to mount. *)

open E2e

let env = { domain = "tsync-e2e"; port = 8788; secret = "e2e-secret" }

(* The mount is the thing under test, so it has to be gone before the directory
   holding it can be. A daemon that has already exited leaves the mount behind
   as an unreachable stub until this runs. *)
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
     store_pid := Some (spawn_daemon ~exe ~home:store_home ());
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
       Some (spawn_daemon ~args:["--mount"; mount] ~exe ~home:mount_home ());
     (* Mounted, not merely started: until FUSE has taken the directory over,
        reads and writes go to the empty directory underneath and every check
        would pass against nothing. *)
     wait_until ~timeout:60. ~what:"the filesystem to be mounted" (fun () ->
         Sys.command
           (Printf.sprintf "mount | grep -q %s" (Filename.quote mount))
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
       Some (spawn_daemon ~args:["--mount"; mount_b] ~exe ~home:client_home ());
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
     run ~env ~mount ~store ~client ~extra:(fun () -> ())
   with
    | Failed msg ->
        Printf.eprintf "staging failed: %s\n" msg;
        finish 1
    | exn ->
        Printf.eprintf "staging failed: %s\n" (Printexc.to_string exn);
        finish 1);

  finish (summary ())
