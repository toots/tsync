(** A backend over a directory on this machine.

    Registers itself as ["local"] and exposes nothing: a caller that wants one
    asks {!Backend.make} for it by name. The library still has to be linked —
    [-linkall] is what puts the registration in the binary. *)
