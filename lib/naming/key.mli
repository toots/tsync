(** The shape of a logical key ([domain_prefix ^ real-path]; a directory key
    ends in ["/"]), in one place. *)

(** [key]'s domain-relative real path. A key that is exactly [domain_prefix] —
    the domain root as a directory key — strips to [""]. A key that does not
    carry the prefix is returned unchanged. *)
val strip_prefix : domain_prefix:string -> string -> string

(** Whether [key] names a directory, i.e. ends in ["/"]. *)
val is_dir : string -> bool

val chop_slash : string -> string

(** Parent of a relative path, with the root spelled [""] rather than
    {!Filename.dirname}'s ["."]. *)
val parent : string -> string

(** [join rel name] is [name] under [rel], with [""] meaning the root. *)
val join : string -> string -> string
