open Lwt.Syntax

type entry = { path : string; latest : int64; versions : int }

module Make (C : Conf.S) = struct
  module B = (val C.store : Backend.S)

  let parse key = Versioning.parse ~versions_prefix:C.versions_prefix key

  (* Version keys are hashed, so the real name is read out of the body a version
     kept rather than derived from the key. *)
  let recorded_name key fallback =
    Lwt.catch
      (fun () ->
        let+ data = B.get ~key () in
        match Manifest.of_string (Bigstring.to_string data) with
          | m -> Manifest.recorded_name m
          | exception _ -> fallback)
      (fun _ -> Lwt.return fallback)

  let live hrel =
    let+ head = B.head_opt ~key:(C.domain_prefix ^ hrel) () in
    head <> None

  let in_folder rel =
    (* Versions of the files in a folder share the folder's id. *)
    let* fid =
      Folder_ids.ensure_id ~cache_root:C.cache_root ~domain_name:C.domain_name
        rel
    in
    let* entries = B.list_prefix ~prefix:(C.versions_prefix ^ fid ^ "/") () in
    let seen = Hashtbl.create 16 in
    Lwt_list.filter_map_s
      (fun (e : Backend.file_entry) ->
        match parse e.Backend.key with
          | Some (hrel, _) when not (Hashtbl.mem seen hrel) ->
              Hashtbl.add seen hrel ();
              let* alive = live hrel in
              if alive then Lwt.return_none
              else
                let+ name = recorded_name e.Backend.key hrel in
                Some name
          | _ -> Lwt.return_none)
      entries

  let in_domain () =
    let latest = Hashtbl.create 64
    and count = Hashtbl.create 64
    and sample = Hashtbl.create 64 in
    let* entries = B.list_prefix ~prefix:C.versions_prefix () in
    List.iter
      (fun (e : Backend.file_entry) ->
        match parse e.Backend.key with
          | Some (rel, ts) ->
              let ts = Int64.of_string ts in
              let best =
                Option.value ~default:0L (Hashtbl.find_opt latest rel)
              in
              if Int64.compare ts best > 0 then Hashtbl.replace latest rel ts;
              Hashtbl.replace sample rel e.Backend.key;
              Hashtbl.replace count rel
                (1 + Option.value ~default:0 (Hashtbl.find_opt count rel))
          | None -> ())
      entries;
    Hashtbl.fold
      (fun rel ts acc ->
        let* acc = acc in
        let* alive = live rel in
        if alive then Lwt.return acc
        else
          let+ path = recorded_name (Hashtbl.find sample rel) rel in
          {
            path;
            latest = ts;
            versions = Option.value ~default:1 (Hashtbl.find_opt count rel);
          }
          :: acc)
      latest (Lwt.return [])
end
