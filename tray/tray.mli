(** Runs until the menu's Quit, a bus that went away, or a signal. Raises
    [Failure] with a printable message when there is no session bus to reach,
    which is what running this outside a desktop session looks like. *)
val run : unit -> unit
