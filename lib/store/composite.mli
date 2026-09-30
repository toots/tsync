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
  chunk_names : string -> Chunk_key.t list;
      (** the chunks a body names, if it is a manifest *)
  generation : unit -> int option;
      (** the collection generation G; [None] when unreadable *)
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

(** [data_dir] holds the copies' job logs under
    [deferred-pending/<domain>/<escaped name>/]. A process that is not the
    domain's [owner] submits copy jobs and calls [poke] instead of running them.
*)
val create :
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
val settle : ?timeout:float -> t -> unit

(** Per copy: name, owed jobs, parked jobs. *)
val copy_stats : t -> (string * int * int) list

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
