open Tsync_core
open Tsync_config
open Tsync_cloud_files_rules

let rec owed_under path acc =
  if Names.is_temp_name (Filename.basename path) then acc
  else (
    match Cf.state path with
      | Some st when st.placeholder && st.in_sync ->
          if st.is_dir && not st.unpopulated then
            Array.fold_left
              (fun acc name -> owed_under (Filename.concat path name) acc)
              acc
              (try Sys.readdir path with Sys_error _ -> [||])
          else acc
      | Some _ -> path :: acc
      | None -> acc)

let owed root =
  List.rev
    (Array.fold_left
       (fun acc name -> owed_under (Filename.concat root name) acc)
       []
       (try Sys.readdir root with Sys_error _ -> [||]))

let rec strip path =
  match Cf.state path with
    | Some st when st.placeholder && st.is_dir && st.unpopulated ->
        Sys.rmdir path
    | Some st when st.is_dir ->
        Array.iter
          (fun name -> strip (Filename.concat path name))
          (try Sys.readdir path with Sys_error _ -> [||]);
        if st.placeholder then Cf.revert path
    | Some st when st.placeholder ->
        if st.dehydrated then Sys.remove path else Cf.revert path
    | _ -> ()

let release ~id root =
  Array.iter
    (fun name ->
      let path = Filename.concat root name in
      try strip path
      with e ->
        Log.warn "cloud_files: releasing %s: %s" path (Printexc.to_string e))
    (try Sys.readdir root with Sys_error _ -> [||]);
  Cf.unregister id;
  Log.info "cloud_files: released %s" root

let registered () =
  let prefix = Sync_root_id.prefix ~sid:(Cf.user_sid ()) in
  List.filter (fun (id, _) -> String.starts_with ~prefix id) (Cf.registered ())

let at_service_start (config : Config.t) =
  let sid = Cf.user_sid () in
  let served =
    List.filter_map
      (fun (d : Config.domain) ->
        if Config.frontend d "cloud_files" = None then None
        else Some (Sync_root_id.id ~sid d.name))
      config.domains
  in
  List.iter
    (fun (id, path) ->
      if not (List.mem id served) then (
        try release ~id path
        with e ->
          Log.warn "cloud_files: releasing %s: %s" path (Printexc.to_string e)))
    (registered ())
