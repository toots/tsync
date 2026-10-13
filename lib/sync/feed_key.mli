(** Feed keys (spec 03 §2.2): [<13-digit ms>-<client id>], naming one line of
    the applied log and what a change-feed anchor carries. Written keys sort
    lexicographically in key order. *)

type t = private string

(** The last [/]-separated segment, if it is a feed key. *)
val parse : string -> t option

val to_string : t -> string
val ms : t -> int64
val compare : t -> t -> int
val equal : t -> t -> bool
val make : ms:int64 -> client:string -> t

type minter

(** Starts past every key [seen]: the head of the applied log. *)
val minter : client:string -> seen:t list -> minter

(** [max(now_ms, last + 1)] with this client's id. *)
val mint : minter -> t
