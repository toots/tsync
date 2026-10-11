(** Feed ops (spec 03 §2.9): a change of the local tree, by path, in the applied
    log and in a local intent. Paths are domain-relative; folder ops carry the
    folder's id. Optional fields are omitted when absent, never [null]. *)

open Tsync_core

type t =
  | Put of { path : string; size : int }
  | Delete of string
  | Mkdir of { path : string; id : Folder_id.t option }
  | Rmdir of { path : string; id : Folder_id.t option }
  | Rename of {
      dst : string;
      src : string;
      is_dir : bool;
      size : int option;
      id : Folder_id.t option;
    }

val to_json : t -> Yojson.Safe.t
val to_string : t -> string

(** Raised for a known op with a missing or invalid field. *)
exception Bad of string

(** [None] for an op this reader does not know (ignored). *)
val of_json : Yojson.Safe.t -> t option

(** The paths an op concerns: [[key]], or [[key; src]] for a rename. *)
val paths : t -> string list

val list_to_json : t list -> Yojson.Safe.t

(** Ops of an applied-log line, dropping the ones that do not decode. *)
val list_of_json_lenient : Yojson.Safe.t -> t list option
