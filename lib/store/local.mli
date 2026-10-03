(** The [local] driver (spec backends/local.md): a store whose objects are files
    under one directory, possibly on a network filesystem.

    Writes are durable before they return, claims are real (hard link or
    no-replace rename), and no symbolic link at or below the root is followed.
*)

(** The driver's config fields (backends/local §2). *)
val fields : Tsync_core.Field_spec.field list

(** [root] is absolute or starts with [~/]; it need not exist. With
    [verify_writes] (the default) every chunk written is read back and its
    corruption marker filed or cleared. On a root local to this host, chunk
    accesses and reference writes go through {!Chunk_spaces}. *)
val create : ?verify_writes:bool -> name:string -> string -> Store.t

(** A fresh random-form temporary name, [.tsync-tmp-<hex>.tmp]. *)
val temp_name : unit -> string

(** [~/…] against [$HOME]. *)
val expand_home : string -> string
