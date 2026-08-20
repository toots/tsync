external is_dataless : string -> bool = "caml_is_dataless"

(* fileproviderd names the domain's folder "<app name>-<domain displayName>"
   after dropping characters it will not put in a path ("Jellyfin Media" becomes
   "TsyncApp-JellyfinMedia"). The rule is undocumented, so compare on letters and
   digits alone. *)

let alnum s =
  String.to_seq (String.lowercase_ascii s)
  |> Seq.filter (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
  |> String.of_seq

let cloud_storage_root () =
  Filename.concat (Sys.getenv "HOME") "Library/CloudStorage"

let is_domain_dir ~domain_name dir = alnum dir = alnum ("TsyncApp" ^ domain_name)

(* [None] until the domain is registered and fileproviderd has created its
   folder, which also tells a caller there is nothing local to look at. *)
let domain_dir ~domain_name =
  let root = cloud_storage_root () in
  match Sys.readdir root with
    | exception _ -> None
    | dirs ->
        Array.find_opt (is_domain_dir ~domain_name) dirs
        |> Option.map (Filename.concat root)

module Make (C : Conf.S) (D : Domain_engine.Domain) = struct
  module F = D.F
  module H = D.Ih

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

  (* [own_only] restricts the match to this domain's folder. *)
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

  (* The multi-domain router uses this to direct path-based requests
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

  (* Nothing journals a change made straight in the bucket, so no delta can
     bridge an anchor issued beforehand and every enumerator must re-list. The
     extension stamps anchors with this token and expires mismatches, which is
     what makes the invalidation durable: the notify below only reaches an
     extension that happens to be running. *)
  let resync_token_path = Filename.concat C.data_dir ("resync-" ^ C.domain_name)

  let stamp_resync_token () =
    try
      let oc = open_out resync_token_path in
      output_string oc (Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.));
      close_out oc
    with Sys_error msg -> Log.err "resync token: %s" msg

  (* Only a process holding an [NSFileProviderManager] can move content in or out
     of the replica, so the daemon asks one to; that process subscribes to us, we
     never reach out. Events are numbered so an acknowledgement can be threaded
     back on the same connection without changing the wire. *)
  let event_seq = ref 0

  let publish ~subs name fields =
    incr event_seq;
    let msg =
      Yojson.Safe.to_string
        (`Assoc
           (("event", `String name)
           :: ("domain", `String C.domain_name)
           :: ("id", `Int !event_seq)
           :: fields))
    in
    Ipc.Subs.publish subs ~topic:C.domain_name msg

  (* A request the user waits on must say it went nowhere rather than report an
     eviction that never happened. *)
  exception No_subscriber

  let () =
    Printexc.register_printer (function
      | No_subscriber ->
          Some
            (Printf.sprintf
               "nothing is listening for '%s': make sure TsyncApp is running, \
                then retry"
               C.domain_name)
      | _ -> None)

  let require_delivery delivered =
    if delivered > 0 then Lwt.return_unit else Lwt.fail No_subscriber

  (* A hint, not a request: the journal carries the same news and the next
     enumeration reads it, so nobody listening is not a failure. *)
  let notify_changed ~subs key =
    ignore (publish ~subs "changed" [("key", `String key)])

  let hooks ~subs =
    H.
      {
        path_to_key;
        evict =
          (fun key ->
            require_delivery (publish ~subs "evict" [("key", `String key)]));
        restore =
          (fun key ->
            require_delivery (publish ~subs "restore" [("key", `String key)]));
        (* [full_resync]'s token is on disk before its event is attempted, which
           is what makes that one durable where this is a hint. *)
        changed = notify_changed ~subs;
        full_resync =
          (fun () ->
            stamp_resync_token ();
            (* The mirror may have just been replaced wholesale by a command in
               another process, and this is the one moment we know a rebuild is
               owed. *)
            let open Lwt.Syntax in
            let* () =
              Folder_ids.rebuild ~cache_root:C.cache_root
                ~domain_name:C.domain_name
            in
            ignore (publish ~subs "resync" []);
            Lwt.return_unit);
        status_fields =
          (fun () ->
            [("subscribers", `Int (Ipc.Subs.count subs ~topic:C.domain_name))]);
        stats_fields =
          (fun () -> ("frontend", `String "file_provider") :: D.stats_fields ());
        on_stop = (fun () -> ());
      }

  (* This frontend's own verb, not a core one: the menu bar app is sandboxed and
     a file in the shared container is "data from other apps" to it, so the bytes
     come from here instead. *)
  open Lwt.Syntax

  let ok_json fields =
    Yojson.Safe.to_string (`Assoc (("ok", `Bool true) :: fields))

  let handle_preview path =
    let* uploads = F.uploads_in_flight () in
    (* Only a body an upload is holding right now, so a caller cannot name a
       path of its own choosing. *)
      match
        List.find_opt
          (fun ({ File_ops.body; _ } : File_ops.in_flight) -> body = Some path)
          uploads
      with
      | None ->
          Lwt.return
            (Yojson.Safe.to_string
               (`Assoc
                  [
                    ("ok", `Bool false);
                    ("code", `String "not_found");
                    ("error", `String "preview: not an upload in flight");
                  ]))
      | Some { File_ops.name; _ } -> (
          (* Under the cache root, so the link QuickLook needs lands on the same
             filesystem as the body it points at. *)
          let scratch = Filename.concat C.cache_root "previews" in
          let+ picture = Preview.of_file ~scratch ~name path in
          match picture with
            | Some picture ->
                ok_json [("data", `String (Base64.encode_string picture))]
            (* Answered, with nothing to show: the caller falls back to an icon
               rather than asking again. *)
            | None -> ok_json [])

  let handler ~subs =
    let core = H.handler (hooks ~subs) in
    fun line ->
      match Yojson.Safe.from_string line with
        | `Assoc obj when List.assoc_opt "action" obj = Some (`String "preview")
          ->
            let path =
              match List.assoc_opt "path" obj with
                | Some (`String s) -> s
                | _ -> ""
            in
            let+ resp = handle_preview path in
            (resp, `Continue)
        | _ | (exception _) -> core line

  let drain = D.drain

  let init ~subs () =
    D.start
      ~on_upload_done:(fun ~key ->
        (* Nothing to drop, the replica keeping the file and the daemon only the
           promoted chunks: upload state is part of the item's version, so a
           finished upload is just another change. *)
        notify_changed ~subs key;
        Lwt.return_unit)
      ()
end

type domain_runtime = {
  prefix : string;
  name : string;
  claims_path : string -> bool;
  handler :
    string -> (string * [ `Continue | `Stop | `Subscribe of string ]) Lwt.t;
  drain : unit -> unit Lwt.t;
}

let start ~served ~socket_path =
  let open Lwt.Syntax in
  (* Detached work has no caller to fail, and the default hook ends the
     process over a background error the log would have carried. *)
  (Lwt.async_exception_hook :=
     fun exn ->
       Log.err "%s: async exception: %s" "file-provider"
         (Printexc.to_string exn));

  let error_json msg =
    Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String msg)])
  in
  (* Subscribers name the domain they want, and events carry it too. *)
  let subs = Ipc.Subs.create () in
  Domain_engine.run (fun ~ready ->
      let* domain_runtimes =
        Lwt_list.map_s
          (fun (sv : Frontend.served) ->
            let module C = (val sv.Frontend.binding.Frontend.conf : Conf.S) in
            let module D = (val sv.Frontend.domain : Domain_engine.Domain) in
            let module R = Make (C) (D) in
            let* () = R.init ~subs () in
            Lwt.return
              {
                prefix = C.domain_prefix;
                name = C.domain_name;
                claims_path = R.claims_path;
                handler = R.handler ~subs;
                drain = R.drain;
              })
          served
      in
      (* The whole menu, for a client that cannot link {!Menu}. Answered here
        rather than by a domain's handler because it spans them: this process
        holds every domain, which is what lets one reply carry the summary and
        the icon as well as the rows. *)
      let menu_reply runtimes =
        let+ statuses =
          Lwt_list.map_s
            (fun r ->
              let+ reply, _ = r.handler {|{"action":"status"}|} in
              Menu.of_status_json ~name:r.name (Yojson.Safe.from_string reply))
            runtimes
        in
        ( Yojson.Safe.to_string
            (`Assoc
               [
                 ("ok", `Bool true);
                 ( "menu",
                   Menu.to_json
                     (Menu.render ~quit_label:"Quit tsync menu bar" statuses) );
               ]),
          `Continue )
      in
      (* The stats submenu's rows, on the same terms: rendered here because the
        client cannot link {!Menu}, and asked for separately because a [stats]
        call reaches every backend -- a round trip nobody wants on the poll that
        runs whether or not the menu is open. *)
      let menu_stats_reply runtimes =
        let+ stats =
          Lwt_list.map_s
            (fun r ->
              let+ reply, _ = r.handler {|{"action":"stats"}|} in
              Menu.of_stats_json (Yojson.Safe.from_string reply))
            runtimes
        in
        ( Yojson.Safe.to_string
            (`Assoc
               [
                 ("ok", `Bool true);
                 ( "rows",
                   Menu.entries_to_json
                     (Menu.stats_entries (List.filter_map Fun.id stats)) );
               ]),
          `Continue )
      in
      let router line =
        match Yojson.Safe.from_string line with
          | exception _ -> Lwt.return (error_json "invalid JSON", `Continue)
          | `Assoc obj ->
              let get_str k =
                match List.assoc_opt k obj with
                  | Some (`String s) -> s
                  | _ -> ""
              in
              let action = get_str "action" in
              let path = get_str "path" in
              let domain = get_str "domain" in
              if action = "menu" then menu_reply domain_runtimes
              else if action = "menu_stats" then
                menu_stats_reply domain_runtimes
              else (
                let runtime_opt =
                  if domain <> "" then
                    List.find_opt (fun r -> r.name = domain) domain_runtimes
                  else (
                    match action with
                      | "evict" | "restore" | "revert" ->
                          (* A filesystem path, not a storage key: resolve it to the
                          domain whose CloudStorage folder contains it. *)
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
                (* A reference carries no domain and folder ids are unique only
                within one, so guessing would resolve a request against a store
                that was never asked. *)
                let runtime =
                  match (runtime_opt, domain_runtimes) with
                    | Some r, _ -> Some r
                    | None, [only] -> Some only
                    | None, _ -> None
                in
                begin match runtime with
                  | Some runtime -> runtime.handler line
                  | None ->
                      Lwt.return
                        ( error_json
                            (Printf.sprintf
                               "cannot tell which domain '%s' is for: name it \
                                with \"domain\""
                               action),
                          `Continue )
                end)
          | _ -> Lwt.return (error_json "expected JSON object", `Continue)
      in
      ready ();
      let* () = Ipc.serve ~subs ~path:socket_path router in
      Lwt_list.iter_s (fun r -> r.drain ()) domain_runtimes)
