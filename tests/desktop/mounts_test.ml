(* Mount discovery (linux-desktop.md §6.1) from fixture files: a config, a
   mount table, a home directory and a tree with a symbolic link. *)
open Tsync_core
open Tsync_config

let child = Array.length Sys.argv > 1

let root =
  if child then Sys.argv.(1)
  else Printf.sprintf "/tmp/tsync-mnt-%d" (Unix.getpid ())

let path = Filename.concat root
let checks = ref 0

let domain ?mount ?(frontends = true) name =
  Printf.sprintf
    {|{"name":%S,"symlinks":"keep","versioning":true,"frontends":[%s],
       "backends":[{"type":"local","name":"main","role":"main","path":"/srv/%s"}]}|}
    name
    (match (frontends, mount) with
      | false, _ -> {|"http-proxy"|}
      | true, None -> {|"fuse"|}
      | true, Some m -> Printf.sprintf {|{"type":"fuse","mountPoint":%S}|} m)
    name

let config =
  Printf.sprintf {|{"name":"test","domains":[%s]}|}
    (String.concat ","
       [
         domain ~mount:(path "mnt/files") "files";
         domain ~mount:(path "mnt/honest") "honest";
         domain ~mount:(path "mnt/ssh") "ssh";
         domain ~mount:(path "mnt/tmp") "tmp";
         domain ~mount:(path "mnt/absent") "absent";
         domain ~mount:(path "mnt/spaced name") "spaced";
         domain "default";
         domain ~mount:(path "link/inside") "linked";
         domain ~mount:(path "mnt/files/nested") "nested";
         domain ~mount:(path "mnt/files/alias/below") "below";
         domain ~frontends:false "headless";
       ])

let line ?(fstype = "fuse.sshfs") ?(source = "tsync") ?(optional = "shared:1")
    mount_point =
  Printf.sprintf "36 35 0:50 / %s rw,nosuid,nodev %s- %s %s rw,user_id=1000"
    mount_point
    (if optional = "" then "" else optional ^ " ")
    fstype source

let table =
  String.concat "\n"
    [
      "22 1 0:21 / / rw,relatime shared:1 - btrfs /dev/sda3 rw";
      line (path "mnt/files");
      line ~fstype:"fuse.tsync" ~optional:"" (path "mnt/honest");
      line ~source:"user@host:/srv" (path "mnt/ssh");
      line ~fstype:"tmpfs" (path "mnt/tmp");
      line ~optional:"shared:2 master:3" (path "mnt/spaced\\040name");
      line (path "home/tsync/default");
      line (path "real/inside");
      line (path "mnt/files/nested");
      line (path "mnt/files/alias/below");
      line (path "home/tsync/headless");
      "garbage";
      "1 2 3 4";
      "40 35 0:51 / /nowhere rw fuse.sshfs tsync rw";
      line (path "mnt/bad\\9zz\\777\\04");
      "";
    ]

let write file text =
  Fs.mkdir_p ~perm:0o700 (Filename.dirname file);
  let oc = open_out file in
  output_string oc text;
  close_out oc

let show title answer =
  incr checks;
  Printf.printf "== %s: %d\n" title (List.length answer);
  List.iter
    (fun (mount_point, socket) ->
      let relative p = Text.replace_all ~sub:root ~by:"<root>" p in
      Printf.printf "  %s  %s\n" (relative mount_point) (relative socket))
    (List.sort compare answer)

let silent_owner socket =
  let fd = Unix.socket PF_UNIX SOCK_STREAM 0 in
  Unix.bind fd (ADDR_UNIX socket);
  Unix.listen fd 8;
  Unix.set_nonblock fd;
  fd

let accepted fd =
  match Unix.accept fd with
    | _ -> 1
    | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> 0

let table_file = path "mountinfo"
let discover () = Mounts.mount_points ~table:table_file ()

(* TSYNC_CONFIG_JSON cannot be unset from OCaml, so the cases that read the
   config file run in a child started without it. *)
let config_file_cases () =
  show "the config as a file" (discover ());
  Sys.remove (path "config/tsync/config.json");
  show "no config" (discover ());
  Printf.printf "%d checks in the child\n" !checks

let () =
  if child then (
    config_file_cases ();
    exit 0);
  List.iter
    (fun d -> Fs.mkdir_p ~perm:0o700 (path d))
    ["home"; "data/tsync"; "mnt"; "real"];
  Unix.symlink (path "real") (path "link");
  (* Below a tsync mount nothing is resolved: this link is never read. *)
  Fs.mkdir_p ~perm:0o700 (path "mnt/files");
  Unix.symlink (path "real") (path "mnt/files/alias");
  Unix.putenv "HOME" (path "home");
  Unix.putenv "XDG_DATA_HOME" (path "data");
  Unix.putenv "XDG_CONFIG_HOME" (path "config");
  Unix.putenv "TSYNC_CONFIG_JSON" config;
  write table_file table;
  let expected = discover () in
  show "the fixture table" expected;

  Printf.printf "== decoding\n";
  List.iter
    (fun s -> Printf.printf "  %S -> %S\n" s (Mounts.decode s))
    [
      "a\\040b"; "a\\011\\012\\134"; "a\\9zz"; "a\\777"; "a\\04"; "a\\"; "\\0401";
    ];

  let owners =
    List.map
      (fun (_, socket) -> silent_owner socket)
      (List.filter (fun (_, s) -> not (Sys.file_exists s)) expected)
  in
  let again = discover () in
  incr checks;
  Printf.printf
    "== owners that accept and never answer: same answer %b, connections %d\n"
    (List.sort compare again = List.sort compare expected)
    (List.fold_left (fun n fd -> n + accepted fd) 0 owners);

  show "no mount table" (Mounts.mount_points ~table:(path "missing") ());
  Unix.putenv "TSYNC_CONFIG_JSON" "{not json";
  show "a config that is not JSON" (discover ());
  Unix.putenv "TSYNC_CONFIG_JSON" {|{"domains":[{"name":"files"}],"bogus":1}|};
  show "a config that fails validation" (discover ());
  Unix.putenv "TSYNC_CONFIG_JSON" config;
  Unix.putenv "HOME" "";
  show "no home directory" (discover ());
  Unix.putenv "HOME" (path "home");
  show "home directory back" (discover ());

  write (path "config/tsync/config.json") config;
  Unix.chmod (path "config/tsync/config.json") 0o600;
  flush stdout;
  let env =
    Array.of_list
      (List.filter
         (fun v -> not (String.starts_with ~prefix:"TSYNC_CONFIG_JSON=" v))
         (Array.to_list (Unix.environment ())))
  in
  let pid =
    Unix.create_process_env Sys.executable_name
      [| Sys.executable_name; root |]
      env Unix.stdin Unix.stdout Unix.stderr
  in
  (match Unix.waitpid [] pid with
    | _, WEXITED 0 -> ()
    | _ -> failwith "the child failed");
  Fs.rm_rf root;
  if !checks = 0 then failwith "no check ran";
  Printf.printf "%d checks\n" !checks
