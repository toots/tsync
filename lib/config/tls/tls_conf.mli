(** Names of the TLS backends compiled into this build, preferred first (e.g.
    ["openssl"; "native"] when both are linked; OpenSSL is faster and leads). *)
val available : unit -> string list

(** Name of the backend conduit will use for the next connection ("native" |
    "openssl" | "none"). *)
val current : unit -> string

(** [apply choice] selects the backend named by [choice]; [None] selects the
    preferred available backend (OpenSSL when compiled in, else Native). A name
    this build does not have falls back to the preferred one with a warning;
    only an unknown name raises [Failure]. *)
val apply : string option -> unit
