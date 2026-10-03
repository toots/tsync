(** A directory watch (spec 01 §14): wakes when the directory's entries change,
    ignoring the temporary names of §2.9. Linux only; elsewhere {!open_} answers
    [None] and the consumer polls. *)

type t

(** [None] when the directory cannot be watched now: absent, or no watch on this
    platform. *)
val open_ : string -> t option

(** Until an entry other than a temporary one changed, the directory went away,
    or [timeout] seconds passed. Spurious wakes are allowed. *)
val wait : t -> timeout:float -> [ `Changed | `Gone | `Timeout ]

val close : t -> unit
