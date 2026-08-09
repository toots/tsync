(** How a frontend names an item to the daemon.

    A path is the wrong name for a directory: renaming one would change what
    every item beneath it is called. Directories already have an id a rename
    does not touch ({!Folder}), so that is what names them here.

    A file is named by its parent's id and its own leaf, which a rename changes
    exactly as a path would: the storage layout gives a file no id of its own,
    so the blast radius is one item rather than a subtree.

    Nothing here spells a storage key or a user's path, the latter mattering
    because these reach system logs. *)

(** The wire forms are ["root"], ["d:<folder id>"], ["f:<folder id>/<leaf>"],
    and anything else as a logical key, for the callers that predate this. *)
type t =
  [ `Root
  | `Dir of string
  | `File of string * string  (** parent folder id, leaf name *)
  | `Key of string
  | `Bad of string  (** unparseable; see {!parse} *) ]

(** Total: an unparseable reference is a value, so a caller answers with an
    error rather than the request failing. *)
val parse : string -> t

val to_string : t -> string

module Make (C : Conf.S) : sig
  (** The logical key an item reference names, or [None] when nothing is there
      any more — the point of the scheme: a caller is told the directory is gone
      rather than handed a path that now resolves to whatever took its place.

      Resolves only what this client already records and mints nothing. *)
  val resolve : t -> string option Lwt.t
end
