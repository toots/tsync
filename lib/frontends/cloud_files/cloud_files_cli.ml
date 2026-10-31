open Tsync_core
open Tsync_config
open Tsync_owner

let fail fmt =
  Printf.ksprintf
    (fun s ->
      prerr_endline ("tsync: " ^ s);
      1)
    fmt

let domain_named name =
  match Option.map Config.of_user_string (Paths.read_config ()) with
    | None -> Error "no config"
    | Some config -> (
        match Config.find_domain config name with
          | Some d -> Ok d
          | None -> Error (Printf.sprintf "no domain %S in the config" name))

(* §13.3: the owner stamps a new generation, so the apply finds its anchor
   stale and walks every populated folder. *)
let reimport ~domain _ =
  match domain_named domain with
    | Error why -> fail "%s" why
    | Ok d -> (
        match Owner.ask d Full_resync with
          | () ->
              print_endline
                ("The sync root of " ^ domain
               ^ " is compared with the domain again.");
              0
          | exception e -> fail "%s" (Fail.classify e).reason)

(* §13.3: a staged edit not yet committed is the only copy of its content. *)
let uncommitted (config : Config.t) =
  List.filter
    (fun (d : Config.domain) ->
      Tsync_checkout.Staged.edits
        (Tsync_checkout.Staged.create ~cache_root:(Paths.cache_root ()) d.name)
      <> [])
    config.domains

let beside name = Filename.concat (Filename.dirname Sys.executable_name) name

(* §13.3: the uninstaller's step, run by tsyncd.exe, whose package identity
   unregistering needs. It keeps the config and every sync root folder. *)
let purge ~domain:_ _ =
  ignore (Sys.command (Filename.quote_command (beside "tsync.exe") ["stop"]));
  let config = Option.map Config.of_user_string (Paths.read_config ()) in
  match Option.map uncommitted config with
    | Some (_ :: _ as held) ->
        fail "nothing was purged: %s hold changes not committed yet"
          (String.concat ", "
             (List.map
                (fun (d : Config.domain) -> Domain_name.to_string d.name)
                held))
    | _ ->
        List.iter
          (fun (id, path) -> Release.release ~id path)
          (Release.registered ());
        ignore
          (Sys.command
             (Filename.quote_command "schtasks"
                ["/Delete"; "/TN"; "\\tsync\\service"; "/F"]));
        Fs.rm_rf (Paths.data_dir ());
        Fs.rm_rf (Paths.cache_root ());
        print_endline "tsync's sync roots, task and local state are removed.";
        0

(* An in-sync placeholder is the domain's, so deleting it loses nothing; its
   state is read again right before, so an edit made meanwhile stays. *)
let rec clear path =
  match Cf.state path with
    | Some st when st.placeholder && st.in_sync && st.is_dir -> (
        if not st.unpopulated then
          Array.iter
            (fun name -> clear (Filename.concat path name))
            (try Sys.readdir path with Sys_error _ -> [||]);
        try Sys.rmdir path with Sys_error _ -> ())
    | Some st when st.placeholder && st.in_sync -> (
        try Sys.remove path with Sys_error _ -> ())
    | _ -> ()

let start_service () =
  ignore
    (Sys.command
       (Filename.quote_command "schtasks" ["/Run"; "/TN"; "\\tsync\\service"]))

(* §13.3, run with the owner stopped; the registration is kept, as the owner
   registers the same settings when it starts. *)
let reset ~domain _ =
  match domain_named domain with
    | Error why -> fail "%s" why
    | Ok d ->
        ignore
          (Sys.command (Filename.quote_command (beside "tsync.exe") ["stop"]));
        let root = Sync_root.of_domain d in
        let children () =
          try Array.to_list (Sys.readdir root) with Sys_error _ -> []
        in
        let held = Release.owed root in
        if held <> [] then (
          start_service ();
          fail
            "nothing was reset: these changes are not in the domain yet:\n  %s"
            (String.concat "\n  " (List.rev held)))
        else (
          List.iter
            (fun name -> clear (Filename.concat root name))
            (children ());
          Fs.unlink_quiet
            (Filename.concat (Paths.data_dir ())
               ("cloudfiles-" ^ Domain_name.to_string d.name ^ ".json"));
          start_service ();
          print_endline
            ("The sync root of " ^ domain
           ^ " is cleared; it fills again from the domain as it is browsed.");
          0)

let commands =
  [
    {
      Frontend.verb = "reset";
      doc =
        "Rebuild the sync root from the domain; refused while it holds a \
         change the domain does not.";
      run = reset;
    };
    {
      Frontend.verb = "purge";
      doc =
        "Release every sync root and remove the service task and local state, \
         keeping the config and the folders; refused while a change is not \
         committed.";
      run = purge;
    };
    {
      Frontend.verb = "reimport";
      doc =
        "Compare the sync root with the domain again, changing what differs.";
      run = reimport;
    };
  ]
