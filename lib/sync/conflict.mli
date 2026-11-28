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

(** [clash_name ~is_dir leaf n]: the name of a key set aside for a name clash
    (conflict-resolution §5): no client in it, so every client computes it. *)
val clash_name : is_dir:bool -> string -> int -> string

(** {!clash_name} for the smallest [n ≥ 1] that is not [taken]. *)
val free_clash : is_dir:bool -> taken:(string -> bool) -> string -> string
