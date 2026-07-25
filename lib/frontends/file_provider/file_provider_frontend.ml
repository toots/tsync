let implementation = "file_provider"

let is_local ~cache_root:_ ~domain_name ~domain_prefix key =
  let pfx = String.length domain_prefix in
  let rel =
    if String.length key > pfx then String.sub key pfx (String.length key - pfx)
    else key
  in
  let normalized =
    String.concat "-"
      (String.split_on_char ' ' (String.lowercase_ascii domain_name))
  in
  let cloud_root = Filename.concat (Sys.getenv "HOME") "Library/CloudStorage" in
  let domain_dir = Filename.concat cloud_root ("TsyncApp-" ^ normalized) in
  let p = Filename.concat domain_dir rel in
  Sys.file_exists p && not (File_provider.is_dataless p)

(* All domains share one IPC socket; the daemon routes by domain prefix. *)
let start bindings =
  (* Leaf process (post-fork): safe to initialize Lwt now. *)
  Frontend.cap_blocking_pool ();
  let paths = Runtime.default_paths () in
  let confs =
    List.map (fun (b : Frontend.binding) -> b.Frontend.conf) bindings
  in
  File_provider.start ~confs ~socket_path:paths.Runtime.socket_path

(* Ask the running daemon to have the File Provider drop its cached index and
   re-enumerate this domain. Reuses the [full_resync] IPC action (routed to the
   domain's runtime by the [domain] field). *)
let reimport (module C : Conf.S) =
  let req =
    `Assoc
      [("action", `String "full_resync"); ("domain", `String C.domain_name)]
  in
  match
    Yojson.Safe.from_string
      (Ipc.send ~socket_path:C.socket_path (Yojson.Safe.to_string req))
  with
    | `Assoc o when List.assoc_opt "ok" o = Some (`Bool true) ->
        Printf.printf "reimport requested for %s\n" C.domain_name
    | _ ->
        Printf.eprintf "reimport failed (is the daemon running?)\n";
        exit 1
    | exception _ ->
        Printf.eprintf "reimport failed (is the daemon running?)\n";
        exit 1

let register () =
  Frontend.register implementation ~cli_group:"fileprovider"
    ~commands:
      [
        {
          Frontend.verb = "reimport";
          doc =
            "Ask the File Provider to drop its cached index and re-enumerate a \
             domain.";
          run = reimport;
        };
      ]
    (module struct
      let is_local = is_local
      let start = start
    end : Frontend.S)
