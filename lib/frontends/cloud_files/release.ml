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
      | Some st when not st.placeholder ->
          (path ^ " (not a placeholder"
          ^ (if st.other_reparse then ", another reparse point" else "")
          ^ ")")
          :: acc
      | Some _ -> (path ^ " (out of sync)") :: acc
      | None -> acc)

let owed root =
  List.rev
    (Array.fold_left
       (fun acc name -> owed_under (Filename.concat root name) acc)
       []
       (try Sys.readdir root with Sys_error _ -> [||]))

(* Each item that could not be released, with why; one failing item leaves
   its siblings to be released. *)
let rec strip path =
  let attempt f =
    try
      f ();
      []
    with e -> [(path, Printexc.to_string e)]
  in
  match Cf.state path with
    | Some st when st.placeholder && st.is_dir && st.unpopulated ->
        attempt (fun () -> Sys.rmdir path)
    | Some st when st.is_dir ->
        let failed =
          List.concat_map
            (fun name -> strip (Filename.concat path name))
            (Array.to_list (try Sys.readdir path with Sys_error _ -> [||]))
        in
        failed
        @ if st.placeholder then attempt (fun () -> Cf.revert path) else []
    | Some st when st.placeholder ->
        attempt (fun () ->
            if st.dehydrated then Sys.remove path else Cf.revert path)
    | _ -> []
    | exception e -> [(path, Printexc.to_string e)]

let release ~id root =
  let failed =
    List.concat_map
      (fun name -> strip (Filename.concat root name))
      (Array.to_list (try Sys.readdir root with Sys_error _ -> [||]))
  in
  List.iter
    (fun (path, why) -> Log.warn "cloud_files: releasing %s: %s" path why)
    failed;
  Cf.unregister id;
  Log.info "cloud_files: released %s" root;
  failed

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
        try ignore (release ~id path)
        with e ->
          Log.warn "cloud_files: releasing %s: %s" path (Printexc.to_string e)))
    (registered ())
