(** A domain's members presented as one store (spec algorithms/replication.md).

    Writes go to every main synchronously, the first main arbitrating; replicas
    and backfills are filled behind the write by durable, bodyless copy jobs
    that bring each key to the mains' state when they run. Reads go to the
    mains, then readable replicas, then read-only archives, failing over past
    held members and never turning "could not look" into "absent". *)

open Tsync_core

type role = Main | Replica | Backfill | Read_only

val role_of_string : string -> role option
val role_to_string : role -> string

(** Read order: main < replica < archive < backfill. *)
val read_rank : role -> int

type member = { name : string; role : role; store : Store.t }

(** Domain knowledge a copy job needs, injected (06 §1). *)
type knowledge = {
  is_index : Key.t -> bool;  (** per-store caches no copy carries *)
  is_journal : Key.t -> bool;
      (** journal entries and the cursor, which a backfill skips *)
}

(** One copy job, as recorded in its log. *)
type job =
  | Put of Key.t
  | Copy of Key.t * Key.t
  | Delete of Key.t
  | Delete_many of Key.t list
  | Collection_delete of {
      keys : Key.t list;
      run : string;
      shard : string;
      generation : int;
    }

type record = {
  job : job;
  attempts : int;
  last_error : (string * string) option;
}

val encode_record : record -> string
val decode_record : string -> record option

(** A member name as a directory name: [A-Za-z0-9._-] kept, other bytes [%XX].
*)
val escape_name : string -> string

type t

(** How often the owner checks its pending discard requests, and how the
    bucket-function probe polls and how long it waits. *)
type timing = { discard_poll : float; probe_poll : float; probe_wait : float }

(** 60 s, 5 s and 180 s. *)
val default_timing : timing

(** [data_dir] holds the copies' job logs under
    [deferred-pending/<domain>/<escaped name>/]. A process that is not the
    domain's [owner] submits copy jobs and calls [poke] instead of running them.
*)
val create :
  ?timing:timing ->
  domain:Domain_name.t ->
  data_dir:string ->
  owner:bool ->
  poke:(unit -> unit) ->
  knowledge:knowledge ->
  member list ->
  t

(** The composite: the store every domain layer uses. *)
val store : t -> Store.t

(** The mains alone: where copy jobs read. *)
val source : t -> Store.t

val domain : t -> Domain_name.t

(** Mains, copies, archives. *)
val members : t -> member list

(** Run the copy logs (owner only). *)
val start : ?paused:bool -> t -> unit

val rescan : t -> unit
val rearm : t -> int
val pause : t -> unit
val resume : t -> unit

(** Run the copies' queues to completion within [timeout]; the owner then
    settles the collection generation once. *)
val settle : ?timeout:float -> t -> unit

(** The job a copy log is running: its key, how long it has run, the chunks its
    manifest names and how many are checked, and the bytes sent. *)
type job_progress = {
  job : string;
  file : (string * int) option;  (** a manifest's name and size *)
  elapsed : float;
  chunks : int;
  checked : int;
  sent : int;
}

(** A copy log: jobs owed, the parked among them, and jobs completed since the
    process started. *)
type copy_stats = {
  copy : string;
  owed : int;
  parked : int;
  done_ : int;
  current : job_progress option;
}

val copy_stats : t -> copy_stats list
val parked : t -> (string * string * Dqueue.failure_note) list

(** The write guard (replication §4.9): refuse to write a non-main member while
    a main is offline, as TRANSIENT/LINK naming it. *)
val guard : t -> member -> string -> unit

(** Record, durably, a collection's deletions owed to one copy. *)
val submit_collection_delete :
  t ->
  member ->
  keys:Key.t list ->
  run:string ->
  shard:string ->
  generation:int ->
  unit

(** Collection deletions of this generation not yet settled on any copy, in this
    process's queues or submitted to the owner. *)
val collection_owed : t -> generation:int -> int

(** Whether this owner confirmed the copy's bucket function within its validity:
    its collection deletions then go through discard requests (gc §5.7). *)
val function_confirmed : t -> member -> bool

(** Probe the copy's bucket function now (object-store-common §3), saving a
    confirmation; [false] for a store that declares none. *)
val probe : ?cancelled:(unit -> bool) -> t -> member -> bool

(** Queue a check of every chunk of the domain on a copy whose bucket function
    this owner confirmed: one verify request per shard (object-store-common §3).
*)
val queue_verification :
  ?cancelled:(unit -> bool) -> t -> member -> [ `Queued of int | `Unsupported ]

(** A discard request present on a copy, with the keys it names and its age. *)
type outstanding = { copy : string; request : Key.t; keys : int; age : float }

val outstanding : t -> outstanding list

(** Rewrite each outstanding request with only the keys the mains still lack,
    deleting one left with none; how many were rewritten or deleted. *)
val retry_outstanding : t -> int
