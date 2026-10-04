(** Command-line path arguments (spec 07 §5.2): the one parser of a token that
    may name an item of a domain, so every command spells [DOMAIN:PATH] alike.
*)

type t =
  | In_domain of { domain : string option; rel : string }
      (** [domain] is [None] for [:PATH], the domain the command resolves *)
  | Local of string  (** absolute *)

(** [DOMAIN:PATH] for a configured [DOMAIN], [:PATH], else a local path, made
    absolute against the working directory. For a command with local sides. *)
val parse : Config.t -> string -> t

(** For a command whose paths are all in a domain: as {!parse}, except that an
    absolute path must lie under a configured mount point, whose domain it
    names, and any other token is relative to the domain the command resolves.
    [Error] is the refusal's sentence. *)
val in_domain : Config.t -> string -> (string option * string, string) result

(** The one domain a command's [--domain] and its tokens name, [None] when none
    names any; [Error] when two differ. *)
val agree : ?name:string -> string option list -> (string option, string) result
