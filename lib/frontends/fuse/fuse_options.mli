(** The [fuse] frontend's options (spec frontends/fuse.md §2.1). Registers
    itself when linked. *)

(** A user name or decimal uid, resolved through the user database. *)
val user_id : string -> int option

(** A group name or decimal gid, resolved through the group database. *)
val group_id : string -> int option

(** Permission bits written as three octal digits, optionally after a leading
    [0]. *)
val mode : string -> int option
