(** The [local] driver (spec backends/local.md): a store whose objects are files
    under one directory, possibly on a network filesystem.

    Writes are durable before they return, claims are real (hard link or
    no-replace rename), and no symbolic link at or below the root is followed.
*)

(** The driver's config fields (backends/local §2). *)
val fields : Tsync_core.Field_spec.field list

(** The collection's reference gate (gc §5.4), run around every put or copy
    whose destination is in a manifest or version area. It receives the body
    being put, or the key being copied, and the write to perform. *)
type gate =
  key:Tsync_core.Key.t ->
  source:[ `Body of string | `Copy_of of Tsync_core.Key.t ] ->
  (unit -> unit) ->
  unit

(** [root] is absolute or starts with [~/]; it need not exist. With
    [verify_writes] (the default) every chunk written is read back and its
    corruption marker filed or cleared. [gate] can be installed later. *)
val create :
  ?verify_writes:bool -> ?gate:gate Atomic.t -> name:string -> string -> Store.t

(** A fresh random-form temporary name, [.tsync-tmp-<hex>.tmp]. *)
val temp_name : unit -> string

(** [~/…] against [$HOME]. *)
val expand_home : string -> string
