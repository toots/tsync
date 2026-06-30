type context = {
  store : File_store.t;
  files : File.store;
  domain_name : string;
  domain_prefix : string;
  mount_point : string;
}

let auto_evict = ref false
let set_pending_version _ek = ()

let make_context ~store ~files ~domain_name ~domain_prefix ~mount_point =
  { store; files; domain_name; domain_prefix; mount_point }

let path_to_key ctx path =
  let rel =
    if path = "/" then ""
    else if path.[0] = '/' then String.sub path 1 (String.length path - 1)
    else path
  in
  ctx.domain_prefix ^ rel

(* ── CLI IPC handler (same text protocol as Linux) ──────────────────────── *)

let cli_handler ctx line =
  let cmd, arg = Ipc.split_cmd line in
  match cmd with
    | "STOP" -> "STOP"
    | "STATUS" ->
        Printf.sprintf {|STATUS {"domain":"%s","running":true}|}
          ctx.domain_name
    | "EVICT" ->
        let key = path_to_key ctx arg in
        File.evict (File.make ~store:ctx.files ~key);
        "OK"
    | "RESTORE" ->
        let key = path_to_key ctx arg in
        (try
           File.ensure_cached (File.make ~store:ctx.files ~key);
           "OK"
         with exn ->
           "ERROR " ^ Printexc.to_string exn)
    | "AUTO_EVICT" -> (
        match arg with
          | "on" ->
              auto_evict := true;
              "OK"
          | "off" ->
              auto_evict := false;
              "OK"
          | _ -> if !auto_evict then "on" else "off")
    | "FULL_RESYNC" ->
        (* ponytail: signal FileProvider extension to re-enumerate *)
        "OK"
    | _ -> "ERROR unknown command"

(* ── Main entry point ────────────────────────────────────────────────────── *)

let mount ctx _argv = Ipc.serve (cli_handler ctx)
