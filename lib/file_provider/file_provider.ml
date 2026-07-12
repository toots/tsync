external is_dataless : string -> bool = "caml_is_dataless"

module Make (C : Conf.S) = struct
  module Sq = Sync_queue.Make (C)
  module F = File.Make (C) (Sq)
  module H = Ipc_handler.Make (C) (F)
  module Sp = Sync_poller.Make (C) (F)

  (* ── Key helpers ──────────────────────────────────────────────────────── *)

  let path_to_key path =
    let path =
      if String.length path >= 2 && path.[0] = '~' && path.[1] = '/' then
        Sys.getenv "HOME" ^ String.sub path 1 (String.length path - 1)
      else path
    in
    let strip_prefix prefix s =
      let n = String.length prefix in
      if String.length s >= n && String.sub s 0 n = prefix then (
        let rest = String.sub s n (String.length s - n) in
        Some
          (if String.length rest > 0 && rest.[0] = '/' then
             String.sub rest 1 (String.length rest - 1)
           else rest))
      else None
    in
    let rel =
      match strip_prefix C.data_dir path with
        | Some r -> r
        | None -> (
            let cloud_root =
              Filename.concat (Sys.getenv "HOME") "Library/CloudStorage"
            in
            let found = ref None in
            (try
               Array.iter
                 (fun d ->
                   if !found = None then
                     found := strip_prefix (Filename.concat cloud_root d) path)
                 (Sys.readdir cloud_root)
             with _ -> ());
            match !found with
              | Some r -> r
              | None ->
                  if path = "/" then ""
                  else if path.[0] = '/' then
                    String.sub path 1 (String.length path - 1)
                  else path)
    in
    C.domain_prefix ^ rel

  (* ── IPC hooks ────────────────────────────────────────────────────────── *)

  (* Eviction and restore are performed by the FileProvider extension; the
     daemon just forwards the request over the notify socket. *)
  let hooks =
    H.
      {
        path_to_key;
        request_evict =
          (fun key ->
            Ipc.notify_evict ~path:C.notify_path key;
            Lwt.return_unit);
        restore =
          (fun key ->
            Ipc.notify_restore ~path:C.notify_path key;
            Lwt.return_unit);
        changed = (fun key -> Ipc.notify_changed ~path:C.notify_path key);
        full_resync =
          (fun () ->
            Ipc.notify_resync ~path:C.notify_path;
            Lwt.return_unit);
        status_fields = (fun () -> []);
        stats_fields =
          (fun () ->
            [
              ("pendingUploads", `Int (Sq.pending ()));
              ("uploadsCompleted", `Int (Sq.completed_count ()));
            ]);
        on_stop = (fun () -> ());
      }

  let handler = H.handler hooks
  let drain = Sq.drain

  let init () =
    let open Lwt.Syntax in
    let* () = Local.init ~cache_root:C.cache_root ~domain_name:C.domain_name in
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_cursor:(fun ~entry_key:_ -> ())
      ~on_upload_done:(fun ~key ->
        (* The daemon copy only exists to stage the upload; drop it now. *)
        let* () = F.evict key in
        Ipc.notify_uploaded ~path:C.notify_path key;
        if Ipc.auto_evict_enabled ~data_dir:C.data_dir then
          Ipc.notify_evict ~path:C.notify_path key;
        Lwt.return_unit);
    Sp.start ~on_changed:(Ipc.notify_changed ~path:C.notify_path) ();
    Lwt.return_unit

  let mount _mount_point =
    Lwt_main.run
      (let open Lwt.Syntax in
       let* () = init () in
       let* () = Ipc.serve ~path:C.socket_path handler in
       drain ())
end

(* ── Multi-domain start ───────────────────────────────────────────────────── *)

let start ~confs ~socket_path =
  let open Lwt.Syntax in
  let error_json msg =
    Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String msg)])
  in
  Lwt_main.run
    (let* domain_runtimes =
       Lwt_list.map_s
         (fun (module C : Conf.S) ->
           let module R = Make (C) in
           let* () = R.init () in
           Lwt.return (C.domain_prefix, C.domain_name, R.handler, R.drain))
         confs
     in
     let router line =
       match Yojson.Safe.from_string line with
         | exception _ -> Lwt.return (error_json "invalid JSON", `Continue)
         | `Assoc obj ->
             let get_str k =
               match List.assoc_opt k obj with Some (`String s) -> s | _ -> ""
             in
             let action = get_str "action" in
             let path = get_str "path" in
             let domain = get_str "domain" in
             let handler_opt =
               match action with
                 | ("cursor" | "changes_since") when domain <> "" ->
                     List.find_opt
                       (fun (_, dn, _, _) -> dn = domain)
                       domain_runtimes
                 | _ ->
                     List.find_opt
                       (fun (pfx, _, _, _) ->
                         let n = String.length pfx in
                         String.length path >= n && String.sub path 0 n = pfx)
                       domain_runtimes
             in
             let _, _, handler, _ =
               match handler_opt with
                 | Some h -> h
                 | None -> List.hd domain_runtimes
             in
             handler line
         | _ -> Lwt.return (error_json "expected JSON object", `Continue)
     in
     let* () = Ipc.serve ~path:socket_path router in
     Lwt_list.iter_s (fun (_, _, _, drain) -> drain ()) domain_runtimes)
