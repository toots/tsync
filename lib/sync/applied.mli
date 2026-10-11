(** The applied log (spec 03 §2.9): one line per change made to the local tree,
    a local operation's or an arrival's, in the order they were made; the local
    change feed. *)

type t

(** [<cache_root>/<domain>/applied/]. *)
val open_ : string -> t

(** Find the head; done once by the owner. *)
val load : t -> unit

(** The key of the last line. *)
val head : t -> Feed_key.t option

(** An op as the log keeps it: with the local id of the file it named when it
    was handled (03 §2.7), never published. *)
type op = { op : Op.t; fid : string option }

(** Append [\n<key>\t<ops>] durably; [fids] by op index. *)
val note : ?fids:(int * string) list -> t -> Feed_key.t -> Op.t list -> unit

type page = { entries : (Feed_key.t * op list) list; more : bool }

(** The entries after the anchor's position, at most [limit]; [`Stale] when the
    anchor is not kept. *)
val since : t -> Feed_key.t option -> int -> [ `Page of page | `Stale ]

(** Remove shards whose keys are all older than [now - keep], never the newest
    nor the shard holding [hold]'s entry or a later one ([`Everything]: none
    goes); [before_drop] runs before each removal. Answers how many. *)
val prune :
  ?hold:[ `Nothing | `Everything | `From of Feed_key.t ] ->
  ?before_drop:(unit -> unit) ->
  t ->
  now:float ->
  keep:float ->
  int
