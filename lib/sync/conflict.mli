(** The conflicted-copy name (spec conflict-resolution §5); it is shown to the
    user and stays stable across versions. *)

(** [name ~client ~is_dir leaf n]: [n ≥ 1]; a folder's leaf is never split. *)
val name : client:string -> is_dir:bool -> string -> int -> string
