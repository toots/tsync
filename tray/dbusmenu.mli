(** The com.canonical.dbusmenu half of the tray.

    The panel draws the menu; this only describes it, one flat tree of numbered
    items with a revision the host watches. Two consequences shape the whole
    module: an item is named by a number the host remembers, and the host is
    told to refetch rather than handed an update. *)

type t

val create : Dbus.connection -> path:string -> t

(** Replace the menu. Ids are freshly allocated and the revision bumped, unless
    the menu is on screen -- then the tree is held and swapped in when it
    closes, since a layout change under an open menu dismisses it. *)
val set : t -> Tray_model.entry list -> unit

(** Run when a row is clicked. Called after the host's request is answered, not
    during: a file manager that is slow to start must not make the menu look
    wedged. *)
val on_click : t -> (Tray_model.action -> unit) -> unit

(** [true] when the message was addressed to us and has been answered. *)
val handle : t -> Dbus.message -> bool
