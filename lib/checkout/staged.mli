(** The staged tree (spec 04 §2.5–2.6): unpublished local writes, the only copy
    of that data, in a tree the cache cap, eviction and resync cannot address.
*)

open Tsync_core
open Tsync_remote

(** Where chunk [i] of an edit comes from: the base's chunk, a hole, or bytes of
    a staged body at an offset. *)
type slot = Inherit | Zero | Staged of { body : string; off : int }

type content = Slots of slot array | Whole of string

(** The content identity the edit started from: unknown, none (no record), or a
    manifest's [h1]. *)
type base = Base_unknown | Base_none | Base of string

(** A local mutation always produces [Owed]; [Committed] carries the manifest
    the upload stored. *)
type state = Owed | Committed of Manifest.t

type edit = {
  name : string;
  size : int;  (** authoritative *)
  mtime : float;
  chunk_size : int;
  content : content;
  base : base;
  state : state;
}

(** Version 2 JSON. *)
val encode : edit -> string

(** [None] for a body that must be set aside (unparseable, or a newer version).
*)
val decode : string -> edit option

type t

val create : cache_root:string -> Domain_name.t -> t
val manifest_path : t -> string -> string
val body_path : t -> string -> string
val whole_path : t -> string -> string
val read : t -> string -> [ `Edit of edit | `Absent | `Unparseable ]
val edit : t -> string -> edit option

(** Replace the staged manifest of a path ([durable] by default). *)
val write : ?durable:bool -> t -> string -> edit -> unit

val remove : t -> string -> unit

(** Every file of the tree: decodable edits with their paths, and files that do
    not decode (to be set aside). *)
val fold :
  t -> ('a -> [ `Edit of string * edit | `Bad of string ] -> 'a) -> 'a -> 'a

val edits : t -> (string * edit) list
val edits_under : t -> string -> (string * edit) list

(** Move a staged manifest, stamping the new leaf. *)
val move : t -> src:string -> dst:string -> unit

val bodies_named : edit -> string list

(** The slots of a chunked edit. *)
val slots : edit -> slot array

val is_set_aside_name : string -> bool
val new_body_id : unit -> string

(** Open a body read-write, creating it exclusively when [create]. *)
val open_body : ?create:bool -> t -> string -> Unix.file_descr

(** The byte length on disk, -1 when absent. *)
val body_size : t -> string -> int

val body_links : t -> string -> int

(** Bytes of a body, zeros past its end; CORRUPT when the body is missing. *)
val read_body : t -> string -> off:int -> len:int -> string

val write_body_at : Unix.file_descr -> off:int -> string -> unit
