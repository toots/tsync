(** Parent of a relative path, with the root spelled [""] rather than
    {!Filename.dirname}'s ["."].

    What is left of a module that described the shape of a logical key: the
    folder-id map is keyed by these paths and climbs them a level at a time. *)
val parent : string -> string
