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

type outcome =
  [ `Kept of string
  | `Removed of string
  | `Left of string * string
  | `Failed of string * string ]

(* One failing item leaves its siblings to be released. *)
let rec strip path : outcome list =
  let attempt done_ f =
    match f () with
      | () -> [done_]
      | exception e -> [`Failed (path, Printexc.to_string e)]
  in
  match Cf.state path with
    | exception e -> [`Failed (path, Printexc.to_string e)]
    | None -> [`Left (path, "its state cannot be read")]
    | Some st when st.placeholder && st.is_dir && st.unpopulated ->
        attempt (`Removed path) (fun () -> Sys.rmdir path)
    | Some st when st.is_dir ->
        List.concat_map
          (fun name -> strip (Filename.concat path name))
          (Array.to_list (try Sys.readdir path with Sys_error _ -> [||]))
        @
        if st.placeholder then attempt (`Kept path) (fun () -> Cf.revert path)
        else []
    | Some st when st.placeholder && st.dehydrated ->
        attempt (`Removed path) (fun () -> Sys.remove path)
    | Some st when st.placeholder ->
        attempt (`Kept path) (fun () -> Cf.revert path)
    | Some _ -> [`Left (path, "not a placeholder")]

let summary root (outcomes : outcome list) =
  let count f = List.length (List.filter f outcomes) in
  Printf.sprintf
    "released %s: %d kept as plain files, %d cloud-only removed, %d left as \
     they were"
    root
    (count (function `Kept _ -> true | _ -> false))
    (count (function `Removed _ -> true | _ -> false))
    (count (function `Left _ -> true | _ -> false))

(* A release's own deletes and renames go through and nothing is fetched; a
   folder is reverted only once complete, and what is not on disk is dropped. *)
let answer connection (r : Cf.request) =
  match r.kind with
    | (`Delete | `Rename | `Dehydrate) as kind ->
        Cf.ack connection r kind `Success
    | `Fetch_placeholders -> Cf.transfer_placeholders connection r `Success []
    | `Fetch_data ->
        Cf.transfer_data connection r `Unsuccessful (Bigstring.create 0)
          ~offset:r.offset ~length:r.length
    | _ -> ()

(* Windows refuses to revert a folder placeholder, or to make anything in the
   sync root, while no provider is connected to it. *)
let connected root f =
  match Cf.connect ~handle:answer root with
    | exception e ->
        Log.info "cloud_files: releasing %s unconnected: %s" root
          (Printexc.to_string e);
        f ()
    | connection ->
        Fun.protect
          ~finally:(fun () ->
            try Cf.disconnect connection
            with e ->
              Log.info "cloud_files: disconnecting %s: %s" root
                (Printexc.to_string e))
          f

let release ~id root =
  let outcomes =
    connected root (fun () ->
        List.concat_map
          (fun name -> strip (Filename.concat root name))
          (Array.to_list (try Sys.readdir root with Sys_error _ -> [||])))
  in
  Cf.unregister id;
  Log.info "cloud_files: %s" (summary root outcomes);
  outcomes

let registered () =
  let sid = Cf.user_sid () in
  Cf.registered ~prefix:(Sync_root_id.prefix ~sid) ~sid

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
