external is_dataless : string -> bool = "caml_is_dataless"

module Make (C : Conf.S) = struct
  module E = Domain_engine.Make (C)
  module Sq = E.Sq
  module F = E.F
  module H = E.Ih
  module Sp = E.Sp

  (* ── Key helpers ──────────────────────────────────────────────────────── *)

  let expand_home path =
    if String.length path >= 2 && path.[0] = '~' && path.[1] = '/' then
      Sys.getenv "HOME" ^ String.sub path 1 (String.length path - 1)
    else path

  let strip_prefix prefix s =
    let n = String.length prefix in
    if String.length s >= n && String.sub s 0 n = prefix then (
      let rest = String.sub s n (String.length s - n) in
      Some
        (if String.length rest > 0 && rest.[0] = '/' then
           String.sub rest 1 (String.length rest - 1)
         else rest))
    else None

  (* The CloudStorage folder fileproviderd creates for a domain is named
     "<app>-<domain displayName>", and the displayName is the domain name.
     ponytail: substring match; tighten if one domain name ever contains
     another's. *)
  let dir_is_own_domain dir =
    let dn = String.length C.domain_name and n = String.length dir in
    let rec search i =
      i + dn <= n && (String.sub dir i dn = C.domain_name || search (i + 1))
    in
    search 0

  (* Strip a "~/Library/CloudStorage/<folder>/" prefix from [path];
     [own_only] restricts the match to this domain's folder. *)
  let strip_cloud_storage ~own_only path =
    let cloud_root =
      Filename.concat (Sys.getenv "HOME") "Library/CloudStorage"
    in
    let found = ref None in
    (try
       Array.iter
         (fun d ->
           if !found = None && ((not own_only) || dir_is_own_domain d) then
             found := strip_prefix (Filename.concat cloud_root d) path)
         (Sys.readdir cloud_root)
     with _ -> ());
    !found

  (* True when [path] lies under this domain's CloudStorage folder; the
     multi-domain router uses this to direct path-based requests
     (evict/restore/revert) to the right domain. *)
  let claims_path path =
    Option.is_some (strip_cloud_storage ~own_only:true (expand_home path))

  let path_to_key path =
    let path = expand_home path in
    let rel =
      match strip_prefix C.data_dir path with
        | Some r -> r
        | None -> (
            match strip_cloud_storage ~own_only:true path with
              | Some r -> r
              | None -> (
                  match strip_cloud_storage ~own_only:false path with
                    | Some r -> r
                    | None ->
                        if path = "/" then ""
                        else if path.[0] = '/' then
                          String.sub path 1 (String.length path - 1)
                        else path))
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
        stats_fields = E.stats_fields;
        on_stop = (fun () -> ());
      }

  let handler = H.handler hooks
  let drain = Sq.drain

  let init () =
    let open Lwt.Syntax in
    E.start
      ~on_cursor:(fun ~entry_key:_ -> ())
      ~on_upload_done:(fun ~key ->
        (* The daemon copy only exists to stage the upload; drop it now. *)
        let* () = F.evict key in
        Ipc.notify_uploaded ~path:C.notify_path key;
        if Ipc.auto_evict_enabled ~data_dir:C.data_dir then
          Ipc.notify_evict ~path:C.notify_path key;
        Lwt.return_unit)
      ~on_changed:(Ipc.notify_changed ~path:C.notify_path)
      ()

  let mount _mount_point =
    Lwt_main.run
      (let open Lwt.Syntax in
       let* () = init () in
       let* () = Ipc.serve ~path:C.socket_path handler in
       drain ())
end

(* ── Multi-domain start ───────────────────────────────────────────────────── *)

type domain_runtime = {
  prefix : string;
  name : string;
  claims_path : string -> bool;
  handler : string -> (string * [ `Continue | `Stop ]) Lwt.t;
  drain : unit -> unit Lwt.t;
}

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
           Lwt.return
             {
               prefix = C.domain_prefix;
               name = C.domain_name;
               claims_path = R.claims_path;
               handler = R.handler;
               drain = R.drain;
             })
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
             let runtime_opt =
               if domain <> "" then
                 List.find_opt (fun r -> r.name = domain) domain_runtimes
               else (
                 match action with
                   | "evict" | "restore" | "revert" ->
                       (* These carry a filesystem path, not a storage key:
                          resolve it to the domain whose CloudStorage folder
                          contains it. *)
                       List.find_opt
                         (fun r -> r.claims_path path)
                         domain_runtimes
                   | _ ->
                       List.find_opt
                         (fun r ->
                           let n = String.length r.prefix in
                           String.length path >= n
                           && String.sub path 0 n = r.prefix)
                         domain_runtimes)
             in
             let runtime =
               match runtime_opt with
                 | Some r -> r
                 | None -> List.hd domain_runtimes
             in
             runtime.handler line
         | _ -> Lwt.return (error_json "expected JSON object", `Continue)
     in
     let* () = Ipc.serve ~path:socket_path router in
     Lwt_list.iter_s (fun r -> r.drain ()) domain_runtimes)
