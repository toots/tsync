(** Where the mirror files each exact name, on a disk that may take several
    names for one slot (spec algorithms/local-names). In each folder the least
    member of each class the disk conflates sits at its own spelling, every
    other member and every unstorable name at its handle. Classes are found by
    asking the disk, never by a stated relation. Every function takes an
    absolute directory and a leaf; changes run under the metadata lock. *)

val dir_marker : string -> string
val name_marker : string -> string

(** [lstat], with a name the disk refuses reaching nothing. *)
val lookup : string -> Unix.LargeFile.stats option

(** An empty regular file: a probe, never an entry. *)
val is_probe : Unix.LargeFile.stats -> bool

(** The entry's own record of its name (§3.1), if it has one. *)
val recorded : string -> Unix.LargeFile.stats -> string option

(** The name the entry at [local] files: its record, else its listed spelling.
*)
val name_of : string -> string -> Unix.LargeFile.stats -> string option

val name_at : string -> string -> string option

(** The local name filing [n], if any (§6). [slot_of] looks at the slots of
    another name instead. *)
val find : ?slot_of:string -> string -> string -> string option

(** Move the ready entry at [from] to [n]'s slot, demoting the class's holder
    when [n] is less (§5); its local name. EXISTS, with nothing changed, when a
    handle it needs is held by another name. *)
val place : ?durable:bool -> string -> from:string -> string -> string

(** After [n] left its folder: when the folder is flagged, the least demoted
    member of [n]'s class takes the plain slot (§4). Idempotent. *)
val promote : string -> string -> unit

(** [drop] the entry filing [n], then {!promote}. *)
val remove : string -> string -> drop:(string -> unit) -> unit
