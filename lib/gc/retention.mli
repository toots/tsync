(** Retention (spec algorithms/gc.md §4): expiry removes the references that
    make chunks garbage, through the domain's composite, and deletes no chunk.
    Without [apply] it is a dry run: every read and decision, every deletion
    reported, nothing written. *)

open Tsync_core

type counts = {
  versions_deleted : int;
  log_deleted : int;  (** log entries; takeovers removed are not counted *)
  shares_deleted : int;  (** share bodies and artifacts *)
}

type report = {
  counts : counts;
  deleted : Key.t list;  (** in order; what a dry run would delete *)
  unparseable_shares : Key.t list;  (** left in place *)
  cancelled : bool;  (** what was left when it was cancelled is not counted *)
}

(** §4.1: the group directories [keys] left empty on each member that is a
    filesystem store. *)
val remove_empty_groups : Tsync_store.Composite.t -> Key.t list -> unit

type listed = { versions_deleted : int; cancelled : bool }

module Make (_ : Tsync_remote.Context.S) : sig
  (** Versions and shares against [cutoff] (seconds since the epoch), and the
      log by its own retention whatever the cutoff, in the order versions, log,
      shares. *)
  val expire :
    ?narrate:Narrate.t ->
    ?apply:bool ->
    ?cancelled:(unit -> bool) ->
    ?now:float ->
    cutoff:float ->
    unit ->
    report

  (** Exactly [keys], resolved from an expiry list (§4.1); the log and shares
      are left alone. *)
  val expire_listed :
    ?narrate:Narrate.t ->
    ?apply:bool ->
    ?cancelled:(unit -> bool) ->
    Key.t list ->
    listed
end
