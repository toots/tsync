(** Client-side name escaping for the local manifest mirror.

    A path component is stored verbatim whenever the filesystem can hold it.
    When it cannot — over the per-component byte limit, or carrying a character
    some filesystem rejects, or colliding with the escape sentinel — it is
    replaced by a fixed-length handle. A handle is lossy, so the real name is
    recovered elsewhere: for a file from its manifest body's [path], for a
    directory from a local-only {!dir_marker} inside it.

    The sentinel leads with a dot, so handles sort together and read as
    internal, and any real name starting with it is itself escaped — which is
    what makes {!is_escaped} unambiguous. *)

(** Name of the local-only file inside an escaped directory holding its real
    name. *)
val dir_marker : string

(** Whether [name] is a handle rather than a real name. *)
val is_escaped : string -> bool

(** One path component, escaped if it cannot be stored as itself. *)
val encode_component : string -> string

(** {!encode_component} over every component of a relative path. *)
val encode_key : string -> string
