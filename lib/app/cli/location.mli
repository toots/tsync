(** Reading a location a user typed.

    Held in one place because a completer offering a value and the command
    receiving it must not be able to disagree about what the value means. *)

(** The domain and the reference a daemon knows an item by, for a command that
    asks a daemon rather than reading the mirror itself. Falls back to asking a
    running daemon where it mounted, which [tsync start --mount] can have moved
    without touching the config. *)
val item :
  ?domain:string -> string -> (string * Item_ref.t, string) result
