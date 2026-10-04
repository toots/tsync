(** The tray (spec frontends/linux-tray.md): a StatusNotifierItem and a dbusmenu
    on the session bus, showing the menu model of every configured domain. *)

(** Runs until the menu's Quit or the bus closing; the exit status of §1, after
    printing its message. Must be called inside the runtime. *)
val run : unit -> int
