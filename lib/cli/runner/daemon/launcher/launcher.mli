(** Starting a machine's frontends: which processes exist, and what each one
    serves.

    Config parsing belongs to the caller, which hands over domains already
    resolved. What is decided here is everything a single frontend cannot decide
    for itself, because it sees one binding and this sees the whole (domain ×
    frontend) matrix. *)

(** One domain's frontends, in config order, each named by its type. The first
    is the one that will keep the domain converging with the store. *)
type domain = (string * Frontend.binding) list

(** Give each frontend its own process and serve until they stop.

    [on_leaf] runs inside each forked process before its frontend starts, named
    for the frontend it is about to run. *)
val run : ?on_leaf:(name:string -> unit) -> domain list -> unit
