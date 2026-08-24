let implementation = "file_provider"

let is_local ({ Conf.domain_name; _ } : Conf.locality) key =
  match File_provider.domain_dir ~domain_name with
    | None -> false
    | Some dir ->
        let p = Filename.concat dir (Logical_key.path key) in
        Sys.file_exists p && not (File_provider.is_dataless p)

(* All domains share one IPC socket; the daemon routes by domain prefix. *)
let start served =
  (* Each conf was handed the socket its domain is reachable at, and here that
     is one path however many domains there are -- so any of them names it. *)
  let socket_path =
    match served with
      | [] -> failwith "file_provider: no domains to serve"
      | sv :: _ ->
          let (module C : Conf.S) = sv.Frontend.binding.Frontend.conf in
          C.socket_path
  in
  File_provider.start ~served ~socket_path

(* Reuses the [full_resync] IPC action, routed to the domain's runtime by the
   [domain] field. *)
let reimport (module C : Conf.S) _args =
  let req =
    `Assoc
      [("action", `String "full_resync"); ("domain", `String C.domain_name)]
  in
  match
    Yojson.Safe.from_string
      (Ipc.send ~socket_path:C.socket_path (Yojson.Safe.to_string req))
  with
    | `Assoc o when List.assoc_opt "ok" o = Some (`Bool true) ->
        Printf.printf "reimport requested for %s\n" C.domain_name
    | _ ->
        Printf.eprintf "reimport failed (is the daemon running?)\n";
        exit 1
    | exception _ ->
        Printf.eprintf "reimport failed (is the daemon running?)\n";
        exit 1

let app_bundle = "/Applications/TsyncApp.app"
let daemon_label = "org.feverdreamtv.tsync.daemon"
let cli_symlink = "/usr/local/bin/tsync"
let sh fmt = Printf.ksprintf (fun cmd -> Sys.command cmd = 0) fmt

(* The app is a login item registered through SMAppService, whose launchd label
   is opaque, so it cannot be kickstarted by name. Killing and reopening the
   bundle is equivalent and fails cleanly when the app is not installed. *)
let restart_app () =
  ignore (sh "pkill -f %s 2>/dev/null" (Filename.quote app_bundle));
  Unix.sleepf 1.;
  sh "open -a %s 2>/dev/null" (Filename.quote app_bundle)

let write_marker ?contents name =
  let dir = (Runtime.default_paths ()).Runtime.data_dir in
  ignore (sh "mkdir -p %s" (Filename.quote dir));
  let path = Filename.concat dir name in
  let oc = open_out_gen [Open_append; Open_creat; Open_wronly] 0o600 path in
  Option.iter (output_string oc) contents;
  close_out oc;
  path

(* Only the app owning the extension may remove a File Provider domain, and it
   reconciles at launch: name the domain in a marker, then bounce the app. *)
let reset (module C : Conf.S) _args =
  let marker =
    write_marker "fileprovider-reset" ~contents:(C.domain_name ^ "\n")
  in
  if not (restart_app ()) then (
    Sys.remove marker;
    Printf.eprintf "reset failed: could not restart TsyncApp\n";
    exit 1);
  Printf.printf "reset requested for %s\n" C.domain_name

(* Only the app can unregister the domains, so that goes first. [config.json]
   lives outside [data_dir] and survives, so `make install` restores
   everything. *)
let purge (_ : (module Conf.S)) _args =
  let paths = Runtime.default_paths () in
  let marker = write_marker "fileprovider-purge" in
  let rec wait attempts =
    if not (Sys.file_exists marker) then true
    else if attempts = 0 then false
    else (
      Unix.sleepf 0.5;
      wait (attempts - 1))
  in
  (* Without the app there is no agent to bounce and no domain registered, so a
     re-run after an interrupted purge falls through to the teardown rather than
     failing on the missing service. *)
  if not (restart_app ()) then (
    Sys.remove marker;
    print_endline "TsyncApp is not running: skipping domain unregistration")
  else if not (wait 60) then (
    Printf.eprintf
      "purge failed: TsyncApp did not unregister its domains (see Console for \
       org.feverdreamtv.tsync)\n";
    exit 1);
  (* The app unregisters its own login item while handling the marker. The
     daemon is a plain LaunchAgent, so its plist has to go too. *)
  ignore (sh "launchctl bootout \"gui/$(id -u)/%s\" 2>/dev/null" daemon_label);
  let agent_plist =
    Filename.concat (Sys.getenv "HOME")
      (Filename.concat "Library/LaunchAgents" (daemon_label ^ ".plist"))
  in
  if Sys.file_exists agent_plist then Sys.remove agent_plist;
  if
    not
      (sh "rm -rf %s %s"
         (Filename.quote app_bundle)
         (Filename.quote paths.Runtime.data_dir))
  then (
    Printf.eprintf "purge: could not remove %s or %s\n" app_bundle
      paths.Runtime.data_dir;
    exit 1);
  Printf.printf "purged: domains, launchd agents, %s, %s\nkept: %s\n" app_bundle
    paths.Runtime.data_dir paths.Runtime.config_path;
  (* [lstat], not [Sys.file_exists]: the app bundle is gone, so the symlink
     dangles. The installer creates it as root, so removing it needs root. *)
  if
    try
      ignore (Unix.lstat cli_symlink);
      true
    with Unix.Unix_error _ -> false
  then (
    try Sys.remove cli_symlink
    with Sys_error _ ->
      Printf.printf "remaining: %s\n  sudo rm %s\n" cli_symlink cli_symlink)

let register () =
  Frontend.register implementation ~cli_group:"fileprovider"
    ~commands:
      [
        {
          Frontend.verb = "reimport";
          doc =
            "Ask the File Provider to drop its cached index and re-enumerate a \
             domain.";
          run = reimport;
        };
        {
          Frontend.verb = "reset";
          doc =
            "Deregister and re-register a domain with the File Provider, \
             dropping its local storage.";
          run = reset;
        };
        {
          Frontend.verb = "purge";
          doc =
            "Remove everything this machine installed: File Provider domains, \
             launchd agents, the app bundle and the cache. Keeps config.json.";
          run = purge;
        };
      ]
    (module struct
      let is_local = is_local
      let topology = `One_process
      let listens = Some `Domain_socket
      let start = start
    end : Frontend.S)
