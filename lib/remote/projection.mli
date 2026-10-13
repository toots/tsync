(** The per-object tree as a projection of the log (spec data-model/backend §6,
    publication §4.7): what applying an entry writes, and the walk a state read
    starts from. Who projects, and under which lease, is the cycle's. *)

open Tsync_core

module Make (_ : Context.S) : sig
  (** Set each key of an entry to its value after, in the four passes of §6.1;
      idempotent. The slots of a pass are read together and its writes issued
      [width] at a time. [before_write] runs before every record write, from any
      of the fibers writing, and raises to stop the projection: no write is
      issued after it raised once. *)
  val apply :
    ?width:int -> before_write:(unit -> unit) -> Log_entry.command list -> unit

  (** The folders that have a namespace in the manifest area, the root included
      (05 §4.7 step 2): one listing of the area. *)
  val namespaces : unit -> Folder_id.t list

  (** Every file record and every folder's anchor of the tree, as the value of
      its key (05 §4.7), in no order; [f] is called by one fiber at a time. A
      namespace that cannot be listed or read fails the walk; a record listed
      and gone or unclassifiable is skipped. [width] namespaces are read at a
      time. *)
  val fold :
    ?width:int ->
    ('a ->
    [ `File of Algebra.place * Manifest.t
    | `Folder of Folder_id.t * Algebra.place ] ->
    'a) ->
    'a ->
    'a
end
