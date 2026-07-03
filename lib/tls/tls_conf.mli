type t = Native | Openssl

val to_string : t -> string
val of_string : string -> t option

(** Names of the TLS backends compiled into this build, preferred first (e.g.
    ["native"; "openssl"] when both are linked). *)
val available : unit -> string list

(** Name of the backend conduit will use for the next connection
    ("native" | "openssl" | "none"). *)
val current : unit -> string

(** Select conduit's TLS backend. Raises [Failure] if it is not available. *)
val set : t -> unit

(** [apply choice] selects the backend named by [choice]; [None] keeps conduit's
    default. Raises [Failure] on an unknown or unavailable name. *)
val apply : string option -> unit
