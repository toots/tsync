type paths = {
  cache_root : string;
  socket_path : string;
  data_dir : string;
  config_path : string;
}

let default_paths () =
  let home = Sys.getenv "HOME" in
  let app_group =
    Filename.concat home "Library/Group Containers/group.org.feverdreamtv.tsync"
  in
  let data_dir = Filename.concat app_group "tsync" in
  {
    cache_root = Filename.concat data_dir "cache";
    socket_path = Filename.concat data_dir "tsync.sock";
    data_dir;
    config_path = Filename.concat app_group "config.json";
  }

(* All domains share the same socket; the daemon routes by domain prefix. *)
let domain_socket_path paths _domain_name = paths.socket_path
let app_bundle = "/Applications/TsyncApp.app"
let daemon_label = "org.feverdreamtv.tsync.daemon"
let sh fmt = Printf.ksprintf (fun cmd -> Sys.command cmd = 0) fmt

(* Where install-agent.sh points the LaunchAgent's stdout and stderr. syslog is
   opened with LOG_PERROR, so this file has every line the unified log has. *)
let log_path =
  Filename.concat (Sys.getenv "HOME") "Library/Logs/tsync-daemon.log"

let log_command ~follow ~lines =
  (["tail"; "-n"; string_of_int lines] @ if follow then ["-f"] else [])
  @ [log_path]

(* Both halves read the config: the daemon at startup, and the app at launch to
   reconcile File Provider domains. [kickstart] both starts a stopped agent and
   restarts a running one, which covers the daemon having exited cleanly for
   want of a config. *)
let restart_service () =
  if not (Sys.file_exists app_bundle) then false
  else begin
    ignore (sh "pkill -f %s 2>/dev/null" (Filename.quote app_bundle));
    ignore
      (sh "launchctl kickstart -k \"gui/$(id -u)/%s\" 2>/dev/null" daemon_label);
    sh "open -a %s 2>/dev/null" (Filename.quote app_bundle)
  end
