open Cmdliner

(* passwords/browser §2: a browser starts the manifest's path with the caller's
   origin first, and on Windows a --parent-window the bridge does not use. *)
let argv =
  match Array.to_list Sys.argv with
    | program :: origin :: _
      when String.starts_with ~prefix:"chrome-extension://" origin ->
        [| program; "passwords"; "browser-host"; origin |]
    | _ -> Sys.argv

let () =
  (* Output ends lines in LF on Windows too, as it does elsewhere. *)
  set_binary_mode_out stdout true;
  set_binary_mode_out stderr true;
  Tsync_config.Paths.claim_group ();
  exit
    (Cmd.eval' ~argv
       (Cmd.group
          (Cmd.info "tsync" ~doc:"Synchronise folders through object stores.")
          (Daemon_cmds.cmds @ Status_cmd.cmds @ Domain_cmds.cmds
         @ Store_cmds.cmds @ Setup_cmds.cmds @ Vault_cmds.cmds @ Totp_cmds.cmds
         @ Passwords_cmds.cmds)))
