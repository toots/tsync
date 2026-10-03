(** The chunk collector (spec algorithms/gc.md §5.5, §5.9): one session per
    collectable main of a domain, each under that main's run lock. The first
    collectable main in role order also owes its deletions to the domain's
    replicas and backfills, through their durable job logs. *)

open Tsync_core
open Tsync_store

type failure =
  | Unsupported of string  (** no main is a local filesystem store *)
  | Busy  (** another session holds a main's run lock *)

type outcome =
  | Completed
  | Suspended of { phase : Gc_record.phase; cursor : string }
      (** the budget ran out at a unit boundary; the run stays open *)
  | Halted of string
      (** a body or area that must not be read as "no references": the run stays
          open, nothing discarded *)

type stats = {
  main : string;
  outcome : outcome;
  roots_marked : int;
  chunks_promoted : int;
  chunks_verified : int;
  chunks_corrupt : int;
  chunks_unreadable : int;
  chunks_cleared : int;
  chunks_reclaimed : int;
  bytes_reclaimed : int;
}

(** What a dry run found on one main; nothing was written. *)
type survey = {
  surveyed : string;
  run : (Gc_record.phase * string) option;  (** an open run, with its cursor *)
  run_unreadable : bool;
  chunks_referenced : int;
  chunks_reclaimable : int;
  bytes_reclaimable : int;
  chunks_missing : Chunk_key.t list;
      (** referenced but absent from the main: damaged files *)
  per_copy : (string * int) list;
      (** deletions a collection would owe each copy *)
  chunks_corrupt : int;  (** with [verify]: referenced chunks that misread *)
}

(** Collect each collectable main: resume or open a run and take it as far as
    [budget] seconds allow and until [cancelled] holds, waiting [pause] between
    units; at least one unit runs. [keep] abandons instead, putting back every
    chunk still outgoing, and [verify] re-hashes each chunk this run promotes,
    filing or clearing its marker.

    Refused with [Unsupported], unless [keep], while the collecting main would
    owe deletions to a remote copy whose bucket function this owner has not
    confirmed: that copy would get one delete request per chunk. *)
val run :
  ?budget:float ->
  ?pause:float ->
  ?narrate:Narrate.t ->
  ?verify:bool ->
  ?keep:bool ->
  ?cancelled:(unit -> bool) ->
  Composite.t ->
  (stats list, failure) result

(** One collectable main as it stands: its run record, the generation, and the
    copy deletions owed under an odd generation. *)
type status = {
  collected : string;
  record : Gc_record.read;
  generation : int option;  (** [None]: unreadable, treated as odd *)
  owed : int;
}

(** Reads only, without the run lock, so it answers beside a running session. *)
val status : Composite.t -> status list

(** Report what a collection would reclaim, per main; [Error reason] inside the
    list when a body stops the survey as it would stop marking, or once
    [cancelled] holds. *)
val dry_run :
  ?narrate:Narrate.t ->
  ?verify:bool ->
  ?cancelled:(unit -> bool) ->
  Composite.t ->
  ((survey, string) result list, failure) result
