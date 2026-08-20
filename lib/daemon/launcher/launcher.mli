(** Starting a machine's frontends: which processes exist, and what each one
    serves.

    Config parsing belongs to the caller, which hands over domains already
    resolved. What is decided here is everything a single frontend cannot decide
    for itself, because it sees one binding and this sees the whole (domain ×
    frontend) matrix. *)

(** One domain as the launcher needs it. [mount_point] is only meaningful to a
    frontend that mounts. *)
type domain = {
  frontends : Conf_parsing.frontend_config list;
  conf : (module Conf.S);
  mount_point : string;
}

(** Build one binding per (domain × frontend), give each frontend its own
    process, and serve until they stop.

    [on_leaf] runs inside each forked process before its frontend starts, named
    for the frontend it is about to run. *)
val run : ?on_leaf:(name:string -> unit) -> domain list -> unit
