(** A domain folder's rows, every page, read inside a fiber: what a listing
    callback presents and what the apply compares (cloud-files §9.1, §10.2). *)

val rows : Tsync_owner.Handler.t -> string -> Tsync_owner.Protocol.row list
