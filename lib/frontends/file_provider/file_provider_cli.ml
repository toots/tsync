open Tsync_core
open Tsync_config
open Tsync_owner

(* file-provider §3.1, §3.2, §13. *)
let app_bundle_id = "org.feverdreamtv.tsync"
let service_label = "org.feverdreamtv.tsync.daemon"
let app_path = "/Applications/TsyncApp.app"
let cli_link = "/usr/local/bin/tsync"
let purge_wait = 60.
let reset_marker () = Filename.concat (Paths.data_dir ()) "fileprovider-reset"
let purge_marker () = Filename.concat (Paths.data_dir ()) "fileprovider-purge"
let say fmt = Printf.printf (fmt ^^ "\n%!")

let fail fmt =
  Printf.ksprintf
    (fun s ->
      prerr_endline ("tsync: " ^ s);
      1)
    fmt

let status args =
  match
    Unix.create_process (List.hd args) (Array.of_list args) Unix.stdin
      Unix.stdout Unix.stderr
  with
    | pid -> ( match snd (Unix.waitpid [] pid) with WEXITED n -> n | _ -> 1)
    | exception Unix.Unix_error _ -> 127

(* Launches the app if it is not running; never terminates a process. *)
let launch_app () = status ["/usr/bin/open"; "-g"; "-b"; app_bundle_id] = 0

let agent_definition () =
  Filename.concat (Paths.home ())
    ("Library/LaunchAgents/" ^ service_label ^ ".plist")

let service_target () =
  Printf.sprintf "gui/%d/%s" (Unix.getuid ()) service_label

let lines file =
  List.filter
    (fun l -> l <> "")
    (String.split_on_char '\n'
       (Option.value ~default:"" (Fs.read_file_opt file)))

let write_lines file = function
  | [] -> if Fs.release file then Fs.fsync_dir (Filename.dirname file)
  | l -> Fs.durable_replace file (String.concat "\n" l ^ "\n")

let ask ~domain req = Protocol.call ~domain (Paths.service_socket ()) req

(* §9.2 *)
let reimport ~domain _ =
  match ask ~domain Full_resync with
    | () ->
        say "Asked the system to enumerate %s again." domain;
        0
    | exception e -> fail "%s" (Fail.classify e).reason

(* §9.3: the app reconciles on the [reset] event, or at its next launch or
   relay acknowledgement. *)
let reach_app ~domain =
  let delivered = try ask ~domain Notify_reset with _ -> 0 in
  delivered > 0 || launch_app ()

let reset ~domain _ =
  let marker = reset_marker () in
  Fs.mkdir_p (Filename.dirname marker);
  let before = lines marker in
  if not (List.mem domain before) then write_lines marker (before @ [domain]);
  if reach_app ~domain then (
    say "Resetting %s: the app removes and adds it again." domain;
    0)
  else (
    write_lines marker (List.filter (( <> ) domain) (lines marker));
    fail "the app could not be reached nor launched; nothing was reset")

let rec wait_gone file deadline =
  if not (Fs.exists file) then true
  else if Unix.gettimeofday () > deadline then false
  else (
    Rt.sleep 0.5;
    wait_gone file deadline)

let remove_link () =
  match Unix.lstat cli_link with
    | { st_kind = S_LNK; _ } -> (
        match Unix.unlink cli_link with
          | () -> ()
          | exception Unix.Unix_error ((EACCES | EPERM), _, _) ->
              say "Remove the command-line link with: sudo rm %s" cli_link)
    | _ | (exception Unix.Unix_error _) -> ()

let remove_app () =
  match Fs.rm_rf app_path with
    | () -> ()
    | exception _ -> say "Remove the app with: sudo rm -rf %s" app_path

(* §9.4 *)
let purge ~domain _ =
  let marker = purge_marker () in
  Fs.mkdir_p (Filename.dirname marker);
  Fs.durable_replace marker "";
  let released =
    if reach_app ~domain then
      wait_gone marker (Unix.gettimeofday () +. purge_wait)
    else (
      say
        "The app is not installed or cannot be launched; skipping \
         unregistration.";
      true)
  in
  if Fs.exists marker then ignore (Fs.release marker);
  if not released then
    fail "the app did not release its domains within %.0fs" purge_wait
  else (
    ignore (status ["/bin/launchctl"; "bootout"; service_target ()]);
    (* §11: no later login starts a service whose bundle is gone. *)
    (try Unix.unlink (agent_definition ()) with Unix.Unix_error _ -> ());
    remove_app ();
    Fs.rm_rf (Paths.data_dir ());
    remove_link ();
    say "Purged tsync; %s is kept." (Paths.config_file ());
    0)

let commands =
  [
    {
      Frontend.verb = "reimport";
      doc = "Make the system enumerate the domain again.";
      run = reimport;
    };
    {
      verb = "reset";
      doc = "Remove the domain from the system and add it again.";
      run = reset;
    };
    {
      verb = "purge";
      doc = "Unregister every domain, stop the service and remove the app.";
      run = purge;
    };
  ]
