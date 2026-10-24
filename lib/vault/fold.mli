(** Folds (spec extensions README §4.2): the changes that settle a record and
    its conflicted copies, a function of their names and bytes only. *)

type file = { name : string; body : string }

type action =
  | Move of { src : string; dst : string }  (** replacing what is at [dst] *)
  | Remove of string
  | Write of { name : string; body : string }

(** [32hexlower]. *)
val is_record_id : string -> bool

(** The grouped fold (README §4.3) of every record id among [files], leaves of
    one extension folder. [open_] is [None] for a file that does not open. *)
val grouped :
  open_:(file -> 'r option) ->
  key:('r -> string) ->
  modified:('r -> int) ->
  file list ->
  action list

(** The keyring fold (vault §4.3) of the file [name] and its copies among
    [files]: the actions, and the copies left for another key id or unreadable.
*)
val keyring : name:string -> file list -> action list * string list
