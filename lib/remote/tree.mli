(** The folder tree on a store (spec 02 §4.3–4.5, data-model/backend §6):
    claiming, confirming and placing folder markers, trash and restore, and
    reads that settle markers by their folder's anchor. *)

open Tsync_core

type body = Dir of Folder.marker | File of Manifest.t
type entry = { key : Tsync_core.Key.t; leaf_hash : string; body : body }

(** A child that cannot be used: listed but gone, a body that classifies as
    nothing (a write in flight), or a marker its folder's anchor disowns. *)
type unusable = Unreadable of Key.t * string | Unclassifiable of Key.t | Disowned of Key.t * Folder.anchor

(** [Fail_on_unusable] fails a folder with an unreadable child (a deleter must
    not take it for empty) and skips unclassifiable ones; [Skip] reports each
    and continues. *)
type on_unusable = Fail_on_unusable | Skip of (unusable -> unit)

val describe_unusable : unusable -> string

module Make (_ : Context.S) : sig
  val anchor : Folder_id.t -> Folder.anchor option

  val placed :
    Folder_id.t -> parent:Folder_id.t -> name:string -> [`Here | `Unanchored | `Elsewhere of Folder.anchor]

  (** The id filed at a slot; disowned markers read as none. *)
  val holder_at : Folder_id.t -> string -> Folder_id.t option

  (** Claim a slot for a candidate id (§6.2 step 1–2): won (anchor written) or
      taken by a filed folder, whose id the caller adopts. *)
  val claim : ?rounds:int -> parent:Folder_id.t -> name:string -> Folder_id.t -> [`Won | `Taken of Folder_id.t]

  (** The confirmation after [claim_settle] (§6.2 step 3). *)
  val confirm : parent:Folder_id.t -> name:string -> Folder_id.t -> [`Final | `Reclaimed | `Lost of Folder_id.t]

  (** Place a settled id (§6.4): anchor first, then the marker's
      create-if-absent. *)
  val place :
    ?rounds:int -> Folder_id.t -> parent:Folder_id.t -> name:string -> [`Placed | `Taken of Folder_id.t | `Taken_by_file]

  (** Place, then remove the old marker if it still names the folder. *)
  val move :
    Folder_id.t ->
    old:Folder_id.t * string ->
    parent:Folder_id.t ->
    name:string ->
    [`Placed | `Taken of Folder_id.t | `Taken_by_file]

  (** Trash entry, anchor "in trash", then the live marker if it names the id. *)
  val trash : Folder_id.t -> old:Folder_id.t * string -> path:string -> unit

  val trash_entries : unit -> (Tsync_store.Store.entry * Folder.marker * string option) list

  (** Place at the destination, then delete the entries naming the id. *)
  val restore : Folder_id.t -> parent:Folder_id.t -> name:string -> [`Placed | `Taken of Folder_id.t | `Taken_by_file]

  (** Delete the marker at a slot only if it still names [id]. *)
  val remove_marker_if : parent:Folder_id.t -> name:string -> Folder_id.t -> unit

  (** A folder's children, classified; disowned markers dropped. *)
  val children : ?on_unusable:on_unusable -> Folder_id.t -> entry list

  (** One read per segment, no listing. *)
  val find : Folder_id.t -> string list -> [`File of Manifest.t | `Folder of Folder_id.t | `Missing]

  (** Depth first, folders before their descent, in an order independent of
      prefetching; [f acc containing_path entry]. *)
  val fold_tree :
    ?on_unusable:on_unusable -> ?width:int -> Folder_id.t -> root_path:string -> ('a -> string -> entry -> 'a) -> 'a -> 'a
end
