(** What an item in a domain is called.

    The name a user gave a file, as the domain thinks of it: a path relative to
    the domain root, and whether it names a file or a folder. Every layer above
    the store speaks these — frontends, the daemon, the journal — and none of
    them spells the prefix or the separator that carries the two apart on the
    wire.

    A store files the same item under a different name, which is
    {!Stored_key}'s. A value of this type is never one of those, which is the
    point of it being a type. *)

type t

(** The wire and store spelling. It says what the item is called and not what
    kind it is: a caller that needs the kind reads {!kind}, and one reading a
    key off the wire is told which by the request it arrived in. *)
val to_string : t -> string

(** The domain-relative path, without a directory's trailing separator, and [""]
    for the root. This is what a journal entry records. *)
val path : t -> string

(** The last component of the path, [""] for the root.

    This is what a manifest filed under this key is called, and the only name a
    writer may record for it: a name derived independently at each writer is a
    name that can disagree with itself. *)
val leaf : t -> string

val kind : t -> [ `File | `Dir ]
val is_root : t -> bool

(** The folder this item sits in; the root is its own parent. *)
val parent : t -> t

(** An item named [name] inside this folder. Raises [Invalid_argument] on a key
    that names a file, which has nothing inside it. *)
val file_in : t -> string -> t

val dir_in : t -> string -> t
val equal : t -> t -> bool
val compare : t -> t -> int

(** One domain's keys. {!Conf.S} satisfies this, so a module already holding one
    applies it directly. *)
module type Domain = sig
  val domain_prefix : string
end

module Make (D : Domain) : sig
  (** From a domain-relative path. A leading or trailing separator is not part
      of the name and is dropped, so a frontend hands over what it has. *)
  val file : string -> t

  val dir : string -> t

  (** The domain root, which is a folder. *)
  val root : t

  (** The domain-relative path a rendered key names, [None] for one belonging to
      another domain or to no domain at all. A path, not a key: the spelling
      carries no kind, so the caller says {!file} or {!dir} from what it is
      doing. *)
  val rel_of_string : string -> string option
end
