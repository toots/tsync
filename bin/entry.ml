open Cmdliner

(* A windowed program starts without standard handles: the null device stands
   in, so printing works and a child spawned with them starts. *)
let attach_missing_handles () =
  List.iter
    (fun (stream, fd, flag) ->
      if Tsync_core.Fs.std_handle_missing stream then (
        let null = Unix.openfile Filename.null [flag] 0 in
        Unix.dup2 ~cloexec:false null fd;
        Unix.close null))
    [
      (`Stdin, Unix.stdin, Unix.O_RDONLY);
      (`Stdout, Unix.stdout, O_WRONLY);
      (`Stderr, Unix.stderr, O_WRONLY);
    ]

(* passwords/browser §2: a browser starts the manifest's path with the caller's
   origin first, and on Windows a --parent-window the bridge does not use. *)
let argv () =
  match Array.to_list Sys.argv with
    | program :: origin :: _
      when String.starts_with ~prefix:"chrome-extension://" origin ->
        [| program; "passwords"; "browser-host"; origin |]
    | _ -> Sys.argv

let main () =
  attach_missing_handles ();
  (* Output ends lines in LF on Windows too, as it does elsewhere. *)
  set_binary_mode_out stdout true;
  set_binary_mode_out stderr true;
  Tsync_config.Paths.claim_group ();
  exit
    (Cmd.eval' ~argv:(argv ())
       (Cmd.group
          (Cmd.info "tsync" ~doc:"Synchronise folders through object stores.")
          (Daemon_cmds.cmds @ Status_cmd.cmds @ Domain_cmds.cmds
         @ Store_cmds.cmds @ Setup_cmds.cmds @ Vault_cmds.cmds @ Totp_cmds.cmds
         @ Passwords_cmds.cmds)))
