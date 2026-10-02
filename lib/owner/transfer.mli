(** Paths a client passes over IPC (security-model §7.3): the owner never uses
    its own privileges on a path the client could not have used. Every refusal
    is DENIED. *)

(** [dest] lies under one of [roots] through directories only, and does not
    exist: the core creates it exclusively. No [roots]: under [/], the path
    rules alone. *)
val check_dest : roots:string list -> string -> unit

(** [staging] lies under one of [roots] through directories only, and is a
    regular file owned by this uid. *)
val check_staging : roots:string list -> string -> unit
