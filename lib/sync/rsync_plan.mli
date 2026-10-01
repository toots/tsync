(** Rsync's decision (spec 05 §4.5): what to do with one entry, from the facts
    gathered about its source and its target. Pure. *)

open Tsync_core

type side = Local | Domain

(** A local file's content as rsync compares it. *)
type local =
  | Link of string  (** a symlink and its target *)
  | Hashed of Chunk_key.t list
      (** chunk keys, cut at the manifest's chunk size it is compared with *)
  | Unhashed

type source = Missing | Dir | File of local | Key of Manifest.t

type target =
  | Absent of side
  | Dir_at of side
  | File_at of local
  | Key_at of Manifest.t

type skip = Source_missing | Target_not_a_dir | Target_is_dir | Not_in_domain

type decision =
  | Skip of skip
  | Make_dir of side
  | Identical
  | Copy_manifest of Manifest.t
  | Rename_in_domain of Manifest.t
  | Upload of [ `Fresh | `Replacing ]
  | Assemble of Manifest.t
  | Patch_local of Manifest.t * int list  (** the chunk indices that differ *)

(** Identity is bytes, never mtime. *)
val unchanged : local -> Manifest.t -> bool

(** The chunks of [m] the local copy lacks, when that can be told. *)
val differing : local -> Manifest.t -> [ `Unknown | `Indices of int list ]

val decide : move:bool -> source -> target -> decision

(** Whether the source is dropped after the decision ran. *)
val disposes : move:bool -> decision -> bool

val skip_name : skip -> string
