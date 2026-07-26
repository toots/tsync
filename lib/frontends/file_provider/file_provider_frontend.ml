let implementation = "file_provider"

let is_local ~cache_root:_ ~domain_name ~domain_prefix key =
  let pfx = String.length domain_prefix in
  let rel =
    if String.length key > pfx then String.sub key pfx (String.length key - pfx)
    else key
  in
  let normalized =
    String.concat "-"
      (String.split_on_char ' ' (String.lowercase_ascii domain_name))
  in
  let cloud_root = Filename.concat (Sys.getenv "HOME") "Library/CloudStorage" in
  let domain_dir = Filename.concat cloud_root ("TsyncApp-" ^ normalized) in
  let p = Filename.concat domain_dir rel in
  Sys.file_exists p && not (File_provider.is_dataless p)

(* All domains share one IPC socket; the daemon routes by domain prefix. *)
let start bindings =
  (* Leaf process (post-fork): safe to initialize Lwt now. *)
  Frontend.cap_blocking_pool ();
  let paths = Runtime.default_paths () in
  let confs =
    List.map (fun (b : Frontend.binding) -> b.Frontend.conf) bindings
  in
  File_provider.start ~confs ~socket_path:paths.Runtime.socket_path

(* Ask the running daemon to have the File Provider drop its cached index and
   re-enumerate this domain. Reuses the [full_resync] IPC action (routed to the
   domain's runtime by the [domain] field). *)
let reimport (module C : Conf.S) =
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
let app_label = "com.toots.tsync"
let daemon_label = "com.toots.tsync.daemon"

let agent_plist label =
  Filename.concat (Sys.getenv "HOME")
    (Filename.concat "Library/LaunchAgents" (label ^ ".plist"))

let sh fmt = Printf.ksprintf (fun cmd -> Sys.command cmd = 0) fmt

let restart_app () =
  sh "launchctl kickstart -k \"gui/$(id -u)/%s\" 2>/dev/null" app_label

let write_marker ?contents name =
  let dir = (Runtime.default_paths ()).Runtime.data_dir in
  ignore (sh "mkdir -p %s" (Filename.quote dir));
  let path = Filename.concat dir name in
  let oc = open_out_gen [Open_append; Open_creat; Open_wronly] 0o600 path in
  Option.iter (output_string oc) contents;
  close_out oc;
  path

(* Only the app owning the extension may remove a File Provider domain, and it
   reconciles domains at launch. So name the domain in a marker the app picks up
   on its next start, then bounce it. *)
let reset (module C : Conf.S) =
  let marker =
    write_marker "fileprovider-reset" ~contents:(C.domain_name ^ "\n")
  in
  if not (restart_app ()) then (
    Sys.remove marker;
    Printf.eprintf "reset failed: could not restart TsyncApp\n";
    exit 1);
  Printf.printf "reset requested for %s\n" C.domain_name

(* Undo the install: unregister the domains (only the app can), then drop the
   launchd agents, the app bundle and the runtime data directory. [config.json]
   lives outside [data_dir] and survives, so `make install` restores everything. *)
let purge (_ : (module Conf.S)) =
  let paths = Runtime.default_paths () in
  let marker = write_marker "fileprovider-purge" in
  let rec wait attempts =
    if not (Sys.file_exists marker) then true
    else if attempts = 0 then false
    else (
      Unix.sleepf 0.5;
      wait (attempts - 1))
  in
  (* Without the app there is no agent to bounce and no domain left registered
     (only the app can register one), so a re-run after an interrupted purge
     falls through to the teardown rather than failing on the missing service. *)
  if not (restart_app ()) then (
    Sys.remove marker;
    print_endline "TsyncApp is not running: skipping domain unregistration")
  else if not (wait 60) then (
    Printf.eprintf
      "purge failed: TsyncApp did not unregister its domains (see Console for \
       com.toots.tsync)\n";
    exit 1);
  List.iter
    (fun label ->
      ignore (sh "launchctl bootout \"gui/$(id -u)/%s\" 2>/dev/null" label);
      let plist = agent_plist label in
      if Sys.file_exists plist then Sys.remove plist)
    [app_label; daemon_label];
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
    paths.Runtime.data_dir paths.Runtime.config_path

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
      let start = start
    end : Frontend.S)
