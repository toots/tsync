(** Where a key lives under a filesystem store's root. *)

(** Raises INVALID when a directory between [root] and the key is a symbolic
    link, REFUSED when one is not a directory. *)
val check_no_links : string -> string -> unit

(** The key's file under [root], checked by {!check_no_links}. *)
val path : string -> Tsync_core.Key.t -> string
