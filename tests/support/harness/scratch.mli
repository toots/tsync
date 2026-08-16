(** A directory a test owns, and gives back.

    Half the tree named a literal ["/tmp/tsync-<name>-test"], which two
    concurrent runs share and fight over, and half called {!Filename.temp_dir},
    which they do not. Both then reimplemented recursive create and delete that
    {!Fs_util} already exports. *)

(** A fresh empty directory for a test called [name], removed and recreated if a
    previous run left one. Unique per process, so two runs of the same test do
    not meet. *)
val dir : string -> string

(** A named child of a scratch directory, created. *)
val sub : string -> string -> string

(** Remove it. Left to the caller rather than done at exit, a failing test being
    worth inspecting. *)
val cleanup : string -> unit
