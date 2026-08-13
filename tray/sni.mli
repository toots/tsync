(** The org.kde.StatusNotifierItem half of the tray.

    An item is not drawn by whoever owns it: it exports an object describing
    itself and asks a watcher to hand it to whatever host is drawing the panel.
    So there is no window here, and nothing to do when nobody is listening --
    which is the state a GNOME session without the AppIndicator extension is
    permanently in. *)

type t

(** The name this process's item is registered under, which is also the name it
    has to own on the bus before registering. *)
val bus_name : unit -> string

(** Answers for [item_path] and asks the watcher to take it, pointing it at
    [menu_path] for the menu. Registration is retried whenever the watcher
    reappears, so starting before the panel does is not a failure. *)
val create : Dbus.connection -> item_path:string -> menu_path:string -> t

(** The icon name and tooltip the item shows. Signals only what changed: a host
    re-reads every property on each [NewIcon], and this is called every poll. *)
val set : t -> icon:string -> tooltip:string -> unit

(** [true] when the message was addressed to us and has been answered. *)
val handle : t -> Dbus.message -> bool

(** Whether a host has claimed the watcher. [false] is not an error -- it is
    what GNOME looks like without its extension -- but it is worth saying once
    at startup. *)
val host_registered : t -> bool
