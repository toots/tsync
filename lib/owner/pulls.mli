(** When the owner of a pulled tree reads the store (android §3.2) and how long
    an answer the mirror can give waits for it (android §3.3). *)

type params = {
  pull_freshness : float;
  view_max_age : float;
  pull_patience : float;
}

(** android §8. *)
val default : params

type t

(** [silent]: the store's health breaker is open. [changed] is told the folders
    whose children a pull changed, or whose listing was answered outdated before
    its pull completed; [recovered] that a store request succeeded after an
    offline answer. *)
val create :
  ?params:params ->
  engine:(module Tsync_sync.Engine.S) ->
  silent:(unit -> bool) ->
  changed:(string list -> unit) ->
  recovered:(unit -> unit) ->
  unit ->
  t

type view = { pulled_at : float option; outdated : bool }

(** Rule 1. A folder with no view to fall back on waits for its pull and raises
    the pull's failure. *)
val for_listing : t -> pull:Protocol.pull -> string -> view

(** The view a page after the first continues: never pulls. *)
val continued : t -> string -> view

(** Rule 2: the destination folder's pull, waited for at most the patience;
    never fails. *)
val before_mutation : t -> string -> unit

(** Rule 3: the file's current manifest, waited for at most the patience. *)
val before_open : t -> string -> unit

(** Rule 4: the pull of a folder a restore walks; raises its failure. *)
val for_walk : t -> string -> unit

(** An [unreachable] answer was given: the next store success is a recovery. *)
val note_unreachable : t -> unit
