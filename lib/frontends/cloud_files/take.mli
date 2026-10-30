(** The take (cloud-files §9.3, §9.4): brings what the user changed in the sync
    root into the domain. The host creates it once its root is connected, feeds
    it the paths its callbacks name, and runs {!start}, which watches the root,
    sweeps it at start, after lost events and every [REPLICA_SWEEP], and takes
    every item it is given on one thread. A take reads the item and decides from
    that alone, so any trigger may repeat. *)

type t

val create :
  engine:(module Tsync_sync.Engine.S) ->
  handler:Tsync_owner.Handler.t ->
  root:string ->
  staging:string ->
  read_only:bool ->
  unit ->
  t

(** Takes the item at the path after [TAKE_SETTLE], once however often it is
    scheduled meanwhile. *)
val schedule : t -> string -> unit

(** Starts the watch, the periodic sweep and the taking thread; a first sweep is
    scheduled at once. *)
val start : t -> unit

(** Items the take refused or cannot hold: links, foreign placeholders, anything
    in a read-only domain (§7.3, §8.1). *)
val untaken : t -> int

val takes : t -> int
