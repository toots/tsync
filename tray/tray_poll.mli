(** Asking each domain's daemon what it is doing.

    Polled rather than subscribed: the daemon publishes events for content
    changes, not for queue depth, and on Linux the FUSE frontend serves no
    event stream at all. A status call costs one round trip on a socket that is
    already there. *)

type domain = { name : string; socket : string; mount : string }

(** The configured domains, re-read when the config file's mtime moves so one
    added by [tsync configure] appears without a restart. A missing or
    unparseable config is an empty list -- the tray says so and keeps running,
    since a config someone is in the middle of editing is not a crash. *)
val domains : unit -> domain list

(** One [status] round trip per domain, all at once and each bounded, so a
    wedged daemon costs one stale row rather than a frozen tray. Never raises:
    a domain that does not answer comes back as {!Tray_model.unreachable}. *)
val poll : domain list -> Tray_model.status list

(** Best effort across every domain, like the macOS switch: one that refuses is
    logged and the rest still change. Nothing is applied locally -- the next
    poll reads back what the daemon did. *)
val set_paused : domain list -> bool -> unit

(** Show [path] in the desktop's file manager: a folder opened, a file selected
    inside its folder. A file is never opened, only revealed -- launching
    whatever owns the type may pull down a body that is still being written. *)
val open_folder : Dbus.connection -> string -> unit

val reveal_file : Dbus.connection -> string -> unit
