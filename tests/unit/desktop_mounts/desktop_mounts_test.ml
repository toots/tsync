(* What a file manager is told about this machine's mounts, driven from fixtures
   rather than whatever happens to be mounted while the suite runs. *)

let failures = ref 0
let checks = ref 0

let check name ok =
  incr checks;
  if ok then Printf.printf "  ok   %s\n" name
  else (
    incr failures;
    Printf.printf "  FAIL %s\n" name)

let scratch = Filename.concat (Filename.get_temp_dir_name ()) "tsync-dm-test"

let write name contents =
  let path = Filename.concat scratch name in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  path

(* Two domains: one with an explicit mountPoint, one relying on the default of
   ~/tsync/<name>. *)
let config home =
  (* The shape [Conf_parsing.load] insists on; only the frontend options vary. *)
  let domain name frontend =
    Printf.sprintf
      {|{"name":"%s","versioning":false,"symlinks":"keep","readOnly":false,
         "backends":[{"name":"store","type":"local","role":"main","path":"/tmp"}],
         "frontends":[%s]}|}
      name frontend
  in
  Printf.sprintf {|{"name":"test","domains":[%s,%s,%s]}|}
    (domain "Explicit"
       (Printf.sprintf {|{"type":"fuse","mountPoint":"%s/elsewhere"}|} home))
    (domain "Jellyfin Media" {|{"type":"fuse"}|})
    (domain "Unmounted"
       (Printf.sprintf {|{"type":"fuse","mountPoint":"%s/gone"}|} home))

(* A real one has more fields and other filesystems; both matter, so both are
   here. The space in the second is escaped, as the kernel writes it. *)
let mountinfo home =
  Printf.sprintf
    "24 30 0:22 / /proc rw,relatime shared:5 - proc proc rw\n\
     31 63 0:86 / %s/elsewhere rw,nosuid shared:9 - fuse.tsync tsync rw\n\
     35 63 0:89 / %s/tsync/Jellyfin\\040Media ro,nosuid shared:1 - fuse.tsync \
     tsync ro\n\
     41 63 0:91 / %s/other rw shared:2 - ext4 /dev/sda1 rw\n"
    home home home

let () =
  (try Unix.mkdir scratch 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let home = Filename.concat scratch "home" in
  (try Unix.mkdir home 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (* [Conf_parsing.mount_point_of] falls back to $HOME/tsync/<name>. *)
  Unix.putenv "HOME" home;
  let paths = Runtime.default_paths () in
  let config_path = write "config.json" (config home) in
  let mountinfo_path = write "mountinfo" (mountinfo home) in
  let found =
    Desktop_mounts.mount_points_in ~config_path ~mountinfo:mountinfo_path ~paths
  in

  check "a mounted domain is reported"
    (List.mem_assoc (home ^ "/elsewhere") found);
  check "its socket is the one its daemon binds"
    (List.assoc_opt (home ^ "/elsewhere") found
    = Some (Runtime.domain_socket_path paths "Explicit"));
  check "a mount point escaped in the table is decoded"
    (List.mem_assoc (home ^ "/tsync/Jellyfin Media") found);
  check "a domain mounting where the config does not say is still found"
    (List.assoc_opt (home ^ "/tsync/Jellyfin Media") found
    = Some (Runtime.domain_socket_path paths "Jellyfin Media"));
  check "a configured domain that is not mounted is left out"
    (not (List.mem_assoc (home ^ "/gone") found));
  check "another filesystem's mount is not ours" (List.length found = 2);
  (* Totality is the wrapper's contract, not [mount_points_in]'s, and it is what
     the C caller depends on: an exception there takes the host with it. *)
  Unix.putenv "HOME" (Filename.concat scratch "no-such-home");
  check "the wrapper answers rather than raising"
    (match Desktop_mounts.mount_points () with
      | _ -> true
      | exception _ -> false);

  Sys.remove config_path;
  Sys.remove mountinfo_path;
  Printf.printf "\n%d/%d checks passed\n" (!checks - !failures) !checks;
  exit (if !failures = 0 && !checks > 0 then 0 else 1)
