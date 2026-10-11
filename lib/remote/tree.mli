(** Reading the folder tree on a store (spec 02 §4.5, data-model/backend §6.2):
    a namespace's children, markers settled by their folder's anchor. The tree
    is written only by {!Projection}. *)

open Tsync_core

type body = Dir of Folder.marker | File of Manifest.t
type entry = { key : Tsync_core.Key.t; leaf_hash : string; body : body }

(** A child that cannot be used: listed but gone, a body that classifies as
    nothing (a write in flight), or a marker its folder's anchor disowns or
    whose folder has no anchor. *)
type unusable =
  | Unreadable of Key.t * string
  | Unclassifiable of Key.t
  | Disowned of Key.t * Folder.anchor option

(** [Fail_on_unusable] fails a folder with an unreadable child (a deleter must
    not take it for empty) and skips unclassifiable ones; [Skip] reports each
    and continues. *)
type on_unusable = Fail_on_unusable | Skip of (unusable -> unit)

val describe_unusable : unusable -> string

module Make (_ : Context.S) : sig
  val anchor : Folder_id.t -> Folder.anchor option

  (** A folder's children, classified; disowned markers dropped. Bodies come
      from the folder index where its entity tags still match (02 §2.10);
      [write_index] (default false) lets this walker rewrite the index. *)
  val children :
    ?on_unusable:on_unusable -> ?write_index:bool -> Folder_id.t -> entry list

  (** One read per segment, no listing. *)
  val find :
    Folder_id.t ->
    string list ->
    [ `File of Manifest.t | `Folder of Folder_id.t | `Missing ]

  (** Depth first, folders before their descent, in an order independent of
      prefetching; [f acc containing_path entry]. *)
  val fold_tree :
    ?on_unusable:on_unusable ->
    ?width:int ->
    ?write_index:bool ->
    Folder_id.t ->
    root_path:string ->
    ('a -> string -> entry -> 'a) ->
    'a ->
    'a
end
