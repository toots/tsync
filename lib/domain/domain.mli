(** A live domain (spec 05 §3): its config, its members' stores, the composite,
    and the engine the owner runs. *)

open Tsync_core
open Tsync_store
open Tsync_sync
open Tsync_config

type t = {
  config : Config.t;
  domain : Config.domain;
  name : Domain_name.t;
  composite : Composite.t;
  members : (Config.backend * Composite.member) list;
  lazy_tree : bool;
  cache_root : string;
  data_dir : string;
  poke : unit -> unit;
}

(** Build without touching a store. A process that is not the domain's [owner]
    submits copy jobs and calls [poke]. *)
val build :
  ?owner:bool ->
  ?poke:(unit -> unit) ->
  ?cache_root:string ->
  ?data_dir:string ->
  Config.t ->
  Config.domain ->
  t

(** Instantiates the engine: opens its logs and caches. Called once, by the
    owner, which keeps it. *)
val engine : t -> (module Engine.S)

(** A store's liveness probe: one cheap read of the domain cursor. *)
val probe : Tsync_core.Domain_name.t -> Store.t -> unit

(** The remote layer's view of the domain, for readers that are not its owner.
    [reading_from] sends every read to that member, writes still going through
    the composite; [reading_at_most] bounds parallel reads (05 §3.1). INVALID
    for an unknown member or a bound below 1. *)
val context :
  ?reading_from:string ->
  ?reading_at_most:int ->
  t ->
  (module Tsync_remote.Context.S)

(** The composite store. *)
val store : t -> Store.t

(** Available, free and total bytes of the tightest writable local member. *)
val capacity : t -> Tsync_core.Fs.space option

(** The refusal text of the domain's pulled frontend, when it has one (08 §2.1).
*)
val pulled : Tsync_config.Config.domain -> string option
