(** A folder id (spec 01 §2.5): the root, the trash, or a hex id. *)

type t = private string

val root : t
val trash : t
val of_string : string -> t option

(** Raises INVALID. *)
val v : string -> t

val to_string : t -> string

(** The only form writers produce: [<first 12 hex of the uuid>-<counter hex>].
*)
val mint : uuid:string -> counter:int -> t

val is_root : t -> bool
val equal : t -> t -> bool
val compare : t -> t -> int
