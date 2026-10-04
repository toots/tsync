(** The dbusmenu tree (spec frontends/linux-tray.md §4.1, §4.3, §4.4): rows with
    ids that are never reused, a revision, and a layout held back while the menu
    is on screen. Not safe for concurrent use. *)

open Tsync_menu

type row = { id : int; entry : Menu_model.entry; children : row list }
type t

(** Empty: the root alone. *)
val create : unit -> t

val revision : t -> int
val rows : t -> row list

(** A row anywhere in the tree. *)
val find : t -> int -> row option

(** Every row, depth first. *)
val all : t -> row list

(** The functions below answer the [LayoutUpdated] to emit, as the id of the
    changed parent; the revision was increased for each. *)

(** §4.3, at a refresh: installed, held while the menu is open, or dropped when
    equal to what is installed. *)
val set_menu : t -> now:float -> Menu_model.entry list -> int list

(** §4.3: the children of the Stats row, open menu or not. *)
val set_stats : t -> Menu_model.entry list -> int list

(** §4.4: an opening notice for this id. *)
val opening : t -> now:float -> int -> int list

(** §4.4: a [closed] event for this id. *)
val closed : t -> int -> int list

(** §10. *)
val menu_open_bound : float
