(** Journal ops (spec 03 §2.3). Paths are domain-relative; folder ops carry the
    folder's id. Optional fields are omitted when absent, never [null]. *)

open Tsync_core

type t =
  | Put of { path : string; size : int; base : string option }
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

val is_put : t -> bool

(** One op per line, each followed by [\n]. *)
val encode_entry : t list -> string

(** Blank lines and surrounding whitespace ignored; [Error] makes the entry
    CORRUPT. *)
val decode_entry : string -> (t list, string) result

val list_to_json : t list -> Yojson.Safe.t

(** Ops of an applied-log line, dropping the ones that do not decode. *)
val list_of_json_lenient : Yojson.Safe.t -> t list option
