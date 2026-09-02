type rename_op = {
  dst : string;
  src : string;
  size : int64 option;
  is_dir : bool;
  id : string option;  (** The folder's id, when [is_dir]. See {!op}. *)
}

(** Directory ops carry the folder's stable id alongside its path: applying a
    removal destroys the local marker the id would have been read from, so an id
    not recorded here cannot be recovered afterwards.

    [None] for entries written before this was carried, and for a client that
    has no id for the folder. *)
type op =
  [ `Delete of string
  | `Mkdir of string * string option
  | `Put of string * int64
  | `Rename of rename_op
  | `Rmdir of string * string option ]

(** Names one unit of work for its whole life: the local record of the intent,
    the published journal object, and the cursors compared against it. Abstract
    because the same key used to have three string spellings — bare, prefixed
    with the journal prefix, and month-sharded — and a reader holding the wrong
    one compared it against the right one and concluded it was behind. *)
module Entry_key : sig
  type t

  (** The only parser. Takes the last path segment, so a backend listing key or
      a stored path is accepted as-is, and returns [None] for a name no client
      wrote rather than raising: callers are listings, where an unreadable name
      is worth reporting, not crashing on. *)
  val of_string : string -> t option

  val to_string : t -> string
  val timestamp_ms : t -> int64
  val client_uuid : t -> string

  (** Chronological — the order ops must be applied in. *)
  val compare : t -> t -> int

  (** Whether the journal cannot carry a reader from [anchor] to now: pruned
      past it, or cleaned up entirely with changes still pending. [keys] is the
      published journal, ascending.

      An empty journal answers [true]: a resync costs a walk, whereas treating
      "no entries" as "nothing happened" silently skips whatever the pruning
      removed. Decided here rather than at the two callers, which had drifted
      into opposite answers for that case. *)
  val cannot_bridge : t -> t list -> bool

  (** ["<YYYY-MM>/<entry key>"], the entry's path relative to the journal
      prefix. Both levels sort chronologically, so the lexicographic order
      readers rely on is unchanged. Only {!File_store} needs this: it is the
      difference between an entry key and a backend key. *)
  val relative_path : t -> string
end

(** One op as it appears in a published entry, and as {!Wal} stores it. *)
val to_json : op -> Yojson.Basic.t

val of_json : Yojson.Basic.t -> op option

(** The keys an op names. A rename touches two: where the item went, and where
    it was, since a reader deciding whether an op concerns it has to test both.
*)
val keys_of_op : op -> string list

(** A published journal entry: one op per line. Unreadable lines are skipped — a
    newer client may have written an op this one does not know. *)
val encode : op list -> string

val decode : string -> op list

module Make (C : Conf.S) : sig
  val client_uuid : unit -> string
  val entry_key : unit -> Entry_key.t
end
