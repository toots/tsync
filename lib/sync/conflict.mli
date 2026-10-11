(** The conflicted-copy name (spec conflict-resolution §5); it is shown to the
    user and stays stable across versions. *)

(** [name ~client ~is_dir leaf n]: [n ≥ 1]; a folder's leaf is never split. *)
val name : client:string -> is_dir:bool -> string -> int -> string

(** [aside(leaf)]: {!name} for the smallest [n ≥ 1] that is not [taken]. *)
val free :
  ?n:int ->
  client:string ->
  is_dir:bool ->
  taken:(string -> bool) ->
  string ->
  string
