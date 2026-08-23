(** What an item in a domain is called.

    The name a user gave a file, as the domain thinks of it: a path relative to
    the domain root, and whether it names a file or a folder. Every layer above
    the store speaks these — frontends, the daemon, the journal — and none of
    them spells the prefix or the separator that carries the two apart on the
    wire.

    Distinct from the key an object is filed under on a backend, which is
    derived from folder ids and a hashed leaf and is {!Layout}'s to produce. A
    value of this type is never one of those, which is the point of it being a
    type. *)

type t

(** The wire and store spelling, and the only place a directory's trailing
    separator is written. *)
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

(** What a listing asks a store for. Raises [Invalid_argument] on a file, there
    being no such thing as the contents of one. *)
val as_prefix : t -> string

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

  (** From a spelling produced by {!to_string}, [None] for one belonging to
      another domain or to no domain at all. For what arrives over a socket or
      out of a record on disk. *)
  val of_string : string -> t option
end
