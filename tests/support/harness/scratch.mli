(** A directory a test owns, and gives back.

    One way of naming a scratch directory for the whole tree: named after the
    test and the process, so two concurrent runs never share one, and cleared on
    the way in, so a run that left something behind does not decide the next
    one. Recursive create and delete come from {!Fs_util} rather than from each
    test. *)

(** A fresh empty directory for a test called [name], removed and recreated if a
    previous run left one. Unique per process, so two runs of the same test do
    not meet. *)
val dir : string -> string

(** A named child of a scratch directory, created. *)
val sub : string -> string -> string

(** Remove it. Left to the caller rather than done at exit, a failing test being
    worth inspecting. *)
val cleanup : string -> unit
