(** An append-only temp file, then a mapping of it.

    A job too large to hold in memory spills to one of these and reads it back
    mapped. The order is not a detail that reads as a bug when got wrong:
    {!Chunk.map_file} is sound only for a file nothing rewrites in place, so the
    channel is closed before the mapping is made, and a file still open for
    append is exactly what that rules out. *)

type t

(** An empty temp file under [dir], which is created; [name] only makes the path
    readable. *)
val create : dir:string -> name:string -> t Lwt.t

val path : t -> string
val append : t -> string -> unit Lwt.t

(** Append the whole contents of [src], which must already be flushed. *)
val append_file : t -> src:string -> unit Lwt.t

(** Close the channel and map the whole finished file. *)
val seal : t -> Chunk.t Lwt.t

(** Close without mapping, for a spool whose bytes are read another way. *)
val close : t -> unit Lwt.t

(** Close and unlink, swallowing a channel already closed. *)
val drop : t -> unit Lwt.t

(** Unlink the spools a killed run left under [dir], one level only. *)
val reap : dir:string -> unit Lwt.t
