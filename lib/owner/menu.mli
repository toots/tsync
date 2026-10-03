(** The menu model shared by the Linux tray and the macOS menu bar (spec 07
    §5.8): a pure function from per-domain [status] answers to the menu JSON. *)

(** A domain's [status], or why it could not be had. *)
type answer = (Protocol.status, string) result

(** [{icon, tooltip, entries}] for the domains, in order. The macOS menu has no
    quit row. *)
val render : (string * answer) list -> Yojson.Safe.t

(** The Stats submenu: one disabled entry per line of a status report. *)
val stats_entries : string -> Yojson.Safe.t list
