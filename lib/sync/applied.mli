(** The applied log (spec 03 §2.7): every journal entry this client handled, its
    own and its peers', in handling order; the dedupe set and the change feed.
*)

type t

(** [<cache_root>/<domain>/applied/]. *)
val open_ : string -> t

(** Read every shard into the handled set; done once by the owner. *)
val load : t -> unit

val contains : t -> Entry_key.t -> bool
val keys : t -> Entry_key.t list

(** The key of the last line. *)
val head : t -> Entry_key.t option

(** Append [\n<key>\t<ops>] durably, once per key. *)
val note : t -> Entry_key.t -> Op.t list -> unit

type page = { entries : (Entry_key.t * Op.t list) list; more : bool }

(** The entries after the anchor's position, at most [limit]; [`Stale] when the
    anchor is not kept. *)
val since : t -> Entry_key.t option -> int -> [ `Page of page | `Stale ]

(** Remove shards whose keys are all older than [now - keep], never the newest;
    answers how many. *)
val prune : t -> now:float -> keep:float -> int
