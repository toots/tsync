(** Reading a location a user typed: a path, or [DOMAIN:/path].

    Held in one place because a completer offering a value and the command
    receiving it must not be able to disagree about what the value means. *)

type place = { name : string; rel : string }
type t = [ `Domain of place | `Local of string ]

(** Which side a bare relative token falls on: [`Either] for a command acting
    on either end of the wire, where [foo] is the local [foo]; [`In_domain] for
    one that only ever means the domain, where [foo] is the domain's. *)
type reading = [ `Either | `In_domain ]

type arg

(** No config is read while parsing: whether [Files:] names a domain, and which
    domain [--domain] narrows to, are neither of them knowable from the token
    alone, and a term is built before a command knows it will need either. *)
val conv : reading -> arg Cmdliner.Arg.conv

(** What was typed, for a report that echoes it back. *)
val typed : arg -> string

val resolve : ?domain:string -> Conf_parsing.t -> arg -> t

(** {!resolve} where [`Local] is not an answer. *)
val place : ?domain:string -> Conf_parsing.t -> arg -> (place, string) result

(** The domain and the reference a daemon knows an item by, for a command that
    asks a daemon rather than reading the mirror itself. Falls back to asking a
    running daemon where it mounted, which [tsync start --mount] can have moved
    without touching the config. *)
val item : ?domain:string -> string -> (string * Item_ref.t, string) result
