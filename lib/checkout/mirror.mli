(** The local mirror of a domain's namespace (spec 04 §2.3–2.4, §4.1, §4.9): one
    manifest file per published file and one directory per folder, filed by real
    path with escape handles, plus the folder-id index.

    Only the owner writes it; other processes may read entries, which are only
    ever replaced by rename. *)

open Tsync_core

type t

val create : cache_root:string -> Domain_name.t -> t

(** [<cache_root>/<domain>]. *)
val root : t -> string

(** The local path of a domain-relative path, escaped component by component. *)
val path : t -> string -> string

type file = [ `File of Manifest.t | `Corrupt | `Dir | `Absent ]

val file : t -> string -> file
val manifest : t -> string -> Manifest.t option
val kind : t -> string -> [ `Dir | `File | `Absent ]

(** The folder id held at a path: [.tsync-root] for the root, the marker's id
    otherwise. Never mints. *)
val folder_id : t -> string -> Folder_id.t option

(** Create the missing folders of a path, escaped, with name markers. *)
val ensure_dirs : t -> string -> unit

(** Replace a file entry with a manifest recording the path's leaf. [own] says
    this client stored it (the own marker, 04 §2.3). [durable] defaults to true.
    EXISTS when the escape handle is held by another name. *)
val write_file : ?durable:bool -> ?own:bool -> t -> string -> Manifest.t -> unit

val remove_file : t -> string -> unit
val is_own : t -> string -> bool

(** Record a folder with an id: directory, markers, removed-id record and
    reverse entry. With [on_other = `Keep] an id already held is kept. *)
val record_folder :
  ?durable:bool ->
  ?on_other:[ `Keep | `Replace ] ->
  t ->
  string ->
  Folder_id.t ->
  [ `Same | `Changed | `Replaced of Folder_id.t | `Held of Folder_id.t ]

(** A folder without an id (created under an op before its mkdir arrives). *)
val mkdir_without_id : t -> string -> unit

val remove_folder : t -> string -> unit

(** Move a folder with every record that names it. *)
val move_folder : t -> src:string -> dst:string -> unit

(** Move a file entry, its own marker and its recorded name. *)
val move_file : t -> src:string -> dst:string -> unit

type child = {
  name : string;
  kind : [ `Dir of Folder_id.t option | `File of Manifest.t ];
}

(** Real names; internal leaves, temporaries and undecodable entries skipped. *)
val list : t -> string -> child list

(** The time the folder's set of children last changed here. *)
val dir_mtime : t -> string -> float

(** The live id, else the id last removed from this path. *)
val lookup_id_removed : t -> string -> Folder_id.t option

(** The current path of an id through the reverse entries, verified against the
    forward marker; a cycle or a stale entry answers nothing. *)
val key_of_id : t -> Folder_id.t -> string option

val whereabouts :
  t ->
  string ->
  [ `Live of Folder_id.t
  | `Moved of Folder_id.t * string
  | `Removed of Folder_id.t
  | `Unknown ]

(** Re-derive the reverse entries from the markers. *)
val rebuild_index : t -> unit

(** Remove every folder marker under a subtree and the path's removed-id record.
*)
val forget_subtree : t -> string -> unit

val sweep_removed_records : t -> older_than:float -> unit
