val chunk_size : int

(** Current manifest body format version (2 = inode layout). *)
val current_version : int

type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

type t = {
  v : int;
  name : string;  (** leaf name; authority for the file's own name *)
  size : int64;
  chunk_size : int;
  chunks : chunk_entry list;
  h1 : string;
  h2 : string;
  mtime : float;
  symlink : string option;
}

type state = [ `Dirty | `Clean of t ]

val chunk_key : chunk_entry -> string

(** Whole-file [h1]/[h2] as a hash over the ordered chunk digests, so a changed
    file's manifest is rebuildable from its chunk entries alone. *)
val digest_of_chunks : chunk_entry list -> string * string

val make :
  name:string ->
  h1:string ->
  h2:string ->
  size:int64 ->
  chunk_size:int ->
  chunks:chunk_entry list ->
  mtime:float ->
  state

(** A chunkless manifest representing a symlink to [target]. *)
val make_symlink : name:string -> target:string -> mtime:float -> state

val of_string : string -> state
val to_string : state -> string

(** [strip_prefix ~domain_prefix key] is [key]'s domain-relative real path. *)
val strip_prefix : domain_prefix:string -> string -> string

(** Where a chunk of a locally edited file has its bytes. *)
type slot =
  | Staged of string  (** a staged body, named by this uuid *)
  | Inherit  (** the published manifest's entry at the same index *)
  | Zero  (** a hole from a grow: reads as zeros, occupies no disk *)

(** A file with unsynced local edits. [s_size] is authoritative — not derived
    from any file length — so a truncate is a metadata write plus at most one
    boundary fixup. Its presence on disk means an upload is owed; once
    [s_published] is set, the upload has already published and what remains is a
    promotion to replay. *)
type staged = {
  s_name : string;
  s_size : int64;
  s_mtime : float;
  s_chunk_size : int;
  s_slots : slot array;
  s_whole : string option;
      (** A whole file handed over by a frontend, named by this uuid: its bytes
          are one file rather than per-chunk bodies, and [s_slots] is empty. The
          upload reads it directly, so taking one costs a rename, not a copy. *)
  s_published : t option;
}

(** Chunk count of a file of [size] at [chunk_size]; 0 for an empty file. *)
val num_chunks_for : int64 -> int -> int

(** Bytes chunk [i] holds in a file of [size] at [chunk_size]. *)
val chunk_len : size:int64 -> chunk_size:int -> int -> int

(** A fresh staged-body id. *)
val new_uuid : unit -> string

(** Whether every byte of [key] is on this machine: it has unsynced edits, or
    the chunk store holds every chunk its sidecar names. Synchronous, for the
    CLI listing; [false] for a partly cached file. *)
val is_local :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  bool

(** The local manifest mirror for one domain: where manifests live, how the tree
    is walked, and the parsed-sidecar cache. Callers name a logical key and
    nothing else — no cache paths, no domain prefixes, no raw bodies. *)
module Make (C : Conf.S) : sig
  (** On-disk path of [key]'s sidecar. Its inode doubles as the existence and
      directory test: directories exist only in this tree. *)
  val path : string -> string

  (** [key]'s manifest, parsed and cached. [None] when absent or unparseable. *)
  val read : string -> state option Lwt.t

  val write : string -> state -> unit Lwt.t
  val delete : string -> unit Lwt.t
  val rename : src_key:string -> dst_key:string -> unit Lwt.t

  (** Drop [key]'s cached parse. Only an optimisation: {!read} revalidates
      against the sidecar's inode, size and mtime anyway, so a sidecar written
      by another process is never served stale. *)
  val invalidate : string -> unit

  val create_dir : string -> unit Lwt.t
  val delete_dir : string -> unit Lwt.t

  (** Rewrite the name marker of a directory that has just moved. *)
  val refresh_dir_marker : string -> unit Lwt.t

  (** Immediate children of [prefix]: file entries (logical keys, size, mtime)
      and real subdirectory names — the one directory listing there is, serving
      both readdir and the frontends' enumeration. Internal markers are filtered
      and names are the real ones, not their escaped on-disk spelling; a staged
      file's own size and mtime win, and it is listed even when nothing of it
      has been published. *)
  val list_directory :
    prefix:string -> unit -> (Backend.file_entry list * string list) Lwt.t

  (** Every file entry under [prefix], recursively. *)
  val list_all : prefix:string -> unit -> Backend.file_entry list Lwt.t

  (** Domain-relative real path of every file the domain holds locally,
      published or only staged (unsorted). *)
  val walk : unit -> string list Lwt.t

  (** [key]'s content, staged edits taking precedence over what was last
      published, with the published manifest alongside for inherited chunks. The
      single resolution point: no caller decides this itself. *)
  val resolve :
    string -> [ `Staged of staged * t option | `Published of t ] option Lwt.t

  val read_staged : string -> staged option Lwt.t
  val write_staged : string -> staged -> unit Lwt.t
  val delete_staged : string -> unit Lwt.t
  val staged_exists : string -> bool Lwt.t
  val rename_staged : src_key:string -> dst_key:string -> unit Lwt.t

  (** Logical keys of every file owing an upload. *)
  val list_staged : unit -> string list Lwt.t

  (** Whether the mirror exists at all — i.e. this domain has a local cache. *)
  val mirror_exists : unit -> bool Lwt.t

  (** Create the mirror root and drop leftover temp files. *)
  val init : unit -> unit Lwt.t
end
