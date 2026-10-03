(** Export (spec 05 §4.4): files of a domain written to a local directory from
    the stores, never through the mirror or the chunk cache, resuming a file
    from its record after an interruption. *)

open Tsync_core

type outcome = Exported of int | Already_there | Failed of string

type report = {
  exported : int;
  bytes : int;  (** written by this run *)
  already_there : int;
  failed : (string * string) list;  (** destination and reason *)
  pending : string list;
      (** this machine's unpublished edits under the paths: reported, their
          published version exported *)
  cancelled : bool;
}

(** [EXPORT_MTIME_SLACK]. *)
val mtime_slack : float

(** [EXPORT_RECORD_GRACE]: 30 days. *)
val record_grace : float

(** The owner's daily sweep (04 §4.11): records older than the grace that no
    export holds locked are removed; how many. *)
val sweep_records : cache_root:string -> Domain_name.t -> int

module Make (_ : Tsync_remote.Context.S) : sig
  (** [paths] are domain-relative ([""] is the root); [dst] must be absolute. A
      missing path, a [.] or [..] segment, or two paths landing on one
      destination fails the run before anything is written. *)
  val export :
    ?narrate:Narrate.t ->
    ?cancelled:(unit -> bool) ->
    cache_root:string ->
    dst:string ->
    string list ->
    report
end
