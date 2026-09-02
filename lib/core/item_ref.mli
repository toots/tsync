(** How a frontend names an item to the daemon.

    A path is the wrong name for a directory: renaming one would change what
    every item beneath it is called. Directories already have an id a rename
    does not touch ({!Stored_key}), so that is what names them here.

    A file is named by its parent's id and its own leaf, which a rename changes
    exactly as a path would: the storage layout gives a file no id of its own,
    so the blast radius is one item rather than a subtree.

    Nothing here spells a storage key, and a user's path only where the caller
    named one, which matters because these reach system logs. Resolving an id to
    the item it names needs the map from ids to paths and belongs to whoever
    holds it. *)

(** The wire forms are ["root"], ["d:<folder id>"] and ["f:<folder id>/<leaf>"],
    each of which says which kind it names. Anything else is {!(`Bad)}, a
    storage key included: a key carries no kind, so accepting one would mean
    guessing, and whoever holds a key holds the mirror that answers it. *)
type t =
  [ `Root
  | `Dir of string
  | `File of string * string  (** parent folder id, leaf name *)
  | `Bad of string  (** unparseable; see {!Make.parse} *) ]

val to_string : t -> string

module Make (D : Logical_key.Domain) : sig
  (** Total: an unparseable reference is a value, so a caller answers with an
      error rather than the request failing. *)
  val parse : string -> t
end
