(** Retention (spec algorithms/gc.md §4): expiry and purge remove the references
    that make chunks garbage, through the domain's composite, and delete no
    chunk. Without [apply] they are a dry run: every read and decision, every
    deletion reported, nothing written. *)

open Tsync_core

type counts = {
  trash_deleted : int;  (** trash entries and purged objects *)
  versions_deleted : int;
  journal_deleted : int;
  shares_deleted : int;  (** share bodies and artifacts *)
}

type report = {
  counts : counts;
  deleted : Key.t list;  (** in order; what a dry run would delete *)
  skipped_recent : Folder_id.t list;  (** trashed again after the cutoff *)
  stopped : (Folder_id.t * string) list;  (** purges a restore interrupted *)
  unparseable_shares : Key.t list;  (** left in place *)
}

type purge = Purged of int | Not_in_trash | Live_elsewhere

module Make (_ : Tsync_remote.Context.S) : sig
  (** Trash, versions, journal, shares, in that order, against [cutoff] (seconds
      since the epoch). The journal keeps every entry younger than the retention
      horizon and the one the cursor names. *)
  val expire : ?apply:bool -> ?now:float -> cutoff:float -> unit -> report

  (** Purge the trashed folder whose trash entry records [path], whatever its
      age; a folder anchored live is refused. *)
  val purge : ?apply:bool -> string -> purge
end
