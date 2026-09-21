(** What a store had at a key, as far as {!Backend.S.watch} needs to compare it.

    Abstract because a key's contents get spelled several ways around here — an
    entry key, a stored key, an etag — and a [watch] concluding "unchanged" from
    the wrong one holds a request it should have answered. Same reason
    {!Journal.Entry_key} is. *)
type t

(** The token for a body a store holds, normalised: the one place the trim
    happens, so a body and a token off a wire cannot differ by whitespace. *)
val of_body : Bigstring.t -> t

(** The wire spelling, for a driver carrying one to its peer, and its only
    parser. Compared with {!equal}, never as strings. *)
val to_wire : t -> string

val of_wire : string -> t
val equal : t -> t -> bool
