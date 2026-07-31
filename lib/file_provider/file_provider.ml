external is_dataless : string -> bool = "caml_is_dataless"

(* ── The domain's CloudStorage folder ──────────────────────────────────────
   fileproviderd names it "<app name>-<domain displayName>" after dropping the
   characters it will not put in a path: displayName "Jellyfin Media" becomes
   "TsyncApp-JellyfinMedia". Rather than reproduce a rule Apple does not
   document, compare on letters and digits alone, which survives whatever else
   it strips or leaves cased. *)

let alnum s =
  String.to_seq (String.lowercase_ascii s)
  |> Seq.filter (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
  |> String.of_seq

let cloud_storage_root () =
  Filename.concat (Sys.getenv "HOME") "Library/CloudStorage"

let is_domain_dir ~domain_name dir = alnum dir = alnum ("TsyncApp" ^ domain_name)

(* [None] until the domain is registered and fileproviderd has created its
   folder, which is also what tells a caller there is nothing local to look at. *)
let domain_dir ~domain_name =
  let root = cloud_storage_root () in
  match Sys.readdir root with
    | exception _ -> None
    | dirs ->
        Array.find_opt (is_domain_dir ~domain_name) dirs
        |> Option.map (Filename.concat root)

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

  let dir_is_own_domain = is_domain_dir ~domain_name:C.domain_name

  (* Strip a "~/Library/CloudStorage/<folder>/" prefix from [path];
     [own_only] restricts the match to this domain's folder. *)
  let strip_cloud_storage ~own_only path =
    let cloud_root = cloud_storage_root () in
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

  (* ── Resync token ─────────────────────────────────────────────────────── *)

  (* A full resync rebuilds the local mirror from the backend listing, which is
     the only way changes made straight in the bucket — writing no journal entry
     — are ever picked up. Nothing journals them, so no delta can bridge a sync
     anchor issued beforehand: every enumerator has to drop its index and
     re-list. The extension stamps its anchors with this token and expires any
     that no longer match, which is what makes the invalidation durable — the
     notify below only reaches an extension that happens to be running, and
     fileproviderd stops ours whenever the domain goes idle. *)
  let resync_token_path = Filename.concat C.data_dir ("resync-" ^ C.domain_name)

  let stamp_resync_token () =
    try
      let oc = open_out resync_token_path in
      output_string oc (Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.));
      close_out oc
    with Sys_error msg -> Log.err "resync token: %s" msg

  (* ── IPC hooks ────────────────────────────────────────────────────────── *)

  (* Only the extension can move content in or out of the replica, and it binds
     its notify socket while it runs and unlinks it on the way out — fileproviderd
     stops it whenever the domain goes idle. So a request the user is waiting on
     has to say it went nowhere rather than report an eviction that never
     happened; browsing the domain in Finder is what starts the extension. *)
  exception Extension_not_running

  let () =
    Printexc.register_printer (function
      | Extension_not_running ->
          Some
            (Printf.sprintf
               "the File Provider extension for '%s' is not running: open the \
                domain's folder in Finder, then retry"
               C.domain_name)
      | _ -> None)

  let require_delivery delivered =
    if delivered then Lwt.return_unit else Lwt.fail Extension_not_running

  let hooks =
    H.
      {
        path_to_key;
        evict =
          (fun key ->
            require_delivery (Ipc.notify_evict ~path:C.notify_path key));
        restore =
          (fun key ->
            require_delivery (Ipc.notify_restore ~path:C.notify_path key));
        (* Hints, not requests: an undelivered one costs nothing because the next
           enumeration carries the same news. [changed] only drops a materialised
           copy early — the item's contentVersion already forces that on re-list —
           and [full_resync]'s token is on disk before this is even attempted. *)
        changed =
          (fun key -> ignore (Ipc.notify_changed ~path:C.notify_path key));
        full_resync =
          (fun () ->
            stamp_resync_token ();
            ignore (Ipc.notify_resync ~path:C.notify_path);
            Lwt.return_unit);
        status_fields = (fun () -> []);
        stats_fields =
          (fun () -> ("frontend", `String "file_provider") :: E.stats_fields ());
        on_stop = (fun () -> ());
      }

  let handler = H.handler hooks
  let drain = Sq.drain

  let init () =
    let open Lwt.Syntax in
    E.start
      ~on_cursor:(fun ~entry_key:_ -> ())
      ~on_upload_done:(fun ~key ->
        (* Nothing to drop: the extension keeps the file, and the daemon keeps
           only the chunks the upload promoted — subject to the cache cap like
           any other. *)
        ignore (Ipc.notify_uploaded ~path:C.notify_path key);
        Lwt.return_unit)
      ~on_changed:(fun key ->
        ignore (Ipc.notify_changed ~path:C.notify_path key))
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
