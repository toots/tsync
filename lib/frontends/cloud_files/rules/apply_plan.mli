(** Applying one folder (cloud-files §10.2): what the sync root must do so the
    folder's children on disk match its presented rows. The host's apply reads
    the domain and the disk, asks {!plan}, and carries the actions out in order;
    nothing owed is ever overwritten, moved or deleted, only taken. *)

type row = {
  ref_ : string;
  leaf : string;
  is_dir : bool;
  is_link : bool;
  size : int;
  mtime : float;
  content_id : string option;
  read_only : bool;
}

(** A child of the folder on disk: [owed] when it is not a placeholder or is out
    of sync (§9.3), and [identity] [None] when it is not the provider's. *)
type child = {
  name : string;
  owed : bool;
  identity : Identity.t option;
  size : int;
  mtime : float;
  read_only : bool;
}

(** Where a reference the folder does not present is: presented in a folder the
    sync root holds and has populated, by that folder's path and the name it
    shows there, or nowhere the sync root shows. *)
type elsewhere = [ `Held of string * string | `Not_held ]

(** The actions, in the order they are carried out:
    - [Take]: an owed child, taken; the folder stays pending.
    - [Refresh]: a child whose content changed, given its new identity and
      metadata and dehydrated.
    - [Update]: a child whose metadata alone changed. *)
type action =
  | Take of string
  | Rename of { from : string; to_ : string }
  | Refresh of { name : string; row : row }
  | Update of { name : string; row : row }
  | Move of { name : string; into : string; as_ : string }
  | Delete of string
  | Create of { name : string; row : row }

(** [fold] maps a name to its form under the volume's case mapping. Temporary
    names (01 §2.9) never reach it. *)
val plan :
  fold:(string -> string) ->
  rows:row list ->
  children:child list ->
  locate:(string -> elsewhere) ->
  action list
