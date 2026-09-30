(** Glob patterns (spec 01 §17): anchored at both ends, byte-wise, [**] only as
    a whole segment, [*] and [?] never cross [/], no escapes or classes. *)

val matches : string -> string -> bool
