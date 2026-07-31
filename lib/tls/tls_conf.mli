type t = Native | Openssl

val to_string : t -> string
val of_string : string -> t option

(** Names of the TLS backends compiled into this build, preferred first (e.g.
    ["openssl"; "native"] when both are linked; OpenSSL is faster and leads). *)
val available : unit -> string list

(** Name of the backend conduit will use for the next connection ("native" |
    "openssl" | "none"). *)
val current : unit -> string

(** Select conduit's TLS backend. Raises [Failure] if it is not available. *)
val set : t -> unit

(** [apply choice] selects the backend named by [choice]; [None] selects the
    preferred available backend (OpenSSL when compiled in, else Native). A name
    this build does not have falls back to the preferred one with a warning —
    which backends are linked is a property of the build, not of the config, and
    both speak TLS. Raises [Failure] only on an unknown name. *)
val apply : string option -> unit
