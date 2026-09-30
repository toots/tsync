(** Entry keys (spec 03 §2.2): [<13-digit ms>-<client id>], naming one unit of
    work from its WAL record to its journal entry, cursor value, applied-log
    line and change-feed anchor. Written keys sort lexicographically in key
    order. *)

open Tsync_core

type t = private string

(** The last [/]-separated segment, if it is an entry key. *)
val parse : string -> t option

val to_string : t -> string
val ms : t -> int64
val client : t -> string
val compare : t -> t -> int
val equal : t -> t -> bool

(** The UTC [YYYY-MM] of its milliseconds: its journal directory. *)
val month : t -> string

val make : ms:int64 -> client:string -> t

(** A key naming a time rather than a unit of work (the last-sync mark). *)
val of_time : client:string -> float -> t

type minter

(** Starts past every key [seen] (the WAL, the applied log, the mark). *)
val minter : client:string -> seen:t list -> minter

val observe : minter -> t -> unit

(** [max(now_ms, last + 1)] with this client's id. *)
val mint : minter -> t

(** [tsync/<d>/journal/<YYYY-MM>/<key>]. *)
val journal_key : Domain_name.t -> t -> Key.t
