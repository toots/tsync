(** The domain items a sync root does not show (cloud-files §7.3): each is
    logged once per owner run with its reason, and counted for status. The
    listing callback and the apply both note what they leave out. *)

type t

val create : unit -> t
val note : t -> ref_:string -> name:string -> string -> unit
val count : t -> int

(** The rows of one folder the sync root shows, with the names it shows them
    under (§7); each row left out, links included, is noted. *)
val present :
  t ->
  on_disk:(string -> bool) ->
  Tsync_owner.Protocol.row list ->
  (Tsync_owner.Protocol.row * string) list
