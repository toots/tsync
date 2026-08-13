open Cmdliner

let run verbose =
  Log.set_min_level (if verbose then `debug else `warn);
  match Tray.run () with
    | () -> 0
    | exception Failure msg ->
        prerr_endline ("tsync-tray: " ^ msg);
        1

let verbose =
  Arg.(value & flag & info ["verbose"; "v"] ~doc:"Print detailed progress")

let cmd =
  Cmd.v
    (Cmd.info "tsync-tray" ~version:"%%VERSION%%"
       ~doc:"Show tsync's sync status in the desktop's system tray"
       ~man:
         [
           `S Manpage.s_description;
           `P
             "Puts an icon in the notification area showing what each \
              configured domain is doing, with a menu listing the files in \
              flight and a switch that pauses uploads. It reads the same \
              daemon each $(b,tsync) command talks to, and runs until quit.";
           `P
             "The icon is drawn by whatever the desktop uses to host \
              StatusNotifierItems. KDE Plasma, XFCE, Cinnamon and LXQt have \
              one built in; GNOME Shell does not, and needs the \
              $(i,AppIndicator and KStatusNotifierItem Support) extension.";
         ])
    Term.(const run $ verbose)

let () = exit (Cmd.eval' ~term_err:1 cmd)
