type paths = { cache_root : string; data_dir : string; config_path : string }

let default_paths () =
  let home = Sys.getenv "HOME" in
  let cache_base =
    match Sys.getenv_opt "XDG_CACHE_HOME" with
      | Some d -> d
      | None -> Filename.concat home ".cache"
  in
  let data_base =
    match Sys.getenv_opt "XDG_DATA_HOME" with
      | Some d -> d
      | None -> Filename.concat home ".local/share"
  in
  let config_base =
    match Sys.getenv_opt "XDG_CONFIG_HOME" with
      | Some d -> d
      | None -> Filename.concat home ".config"
  in
  let data_dir = Filename.concat data_base "tsync" in
  {
    cache_root = Filename.concat cache_base "tsync";
    data_dir;
    config_path = Filename.concat config_base "tsync/config.json";
  }

(* Each FUSE domain runs in its own child process, so each needs its own socket. *)
let domain_socket_path paths domain_name =
  Filename.concat paths.data_dir ("tsync-" ^ domain_name ^ ".sock")

let restart_service () =
  Sys.command "systemctl --user restart tsync 2>/dev/null" = 0

(* Requires systemd-journald: the daemon logs through syslog(3) and ships no log
   file of its own, so on a non-systemd system there is nothing here to read.

   Matched by syslog identity, not by unit — the ident comes from the daemon's
   own openlog, so renaming or reinstancing the unit cannot cost us the log. *)
let log_command ~follow ~lines =
  ["journalctl"; "-t"; "tsync"; "-n"; string_of_int lines]
  @ if follow then ["-f"] else []
