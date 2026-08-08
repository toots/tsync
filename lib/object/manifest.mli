(** A published file's metadata. Header fields are lifted out of the body;
    [chunks] is the body itself ({!Chunk_table}), mapped for a sidecar, so chunk
    keys cost no heap until one is asked for.

    No [name]: a name belongs to where a manifest is filed, not to the manifest.
    The body carries one only because some locations cannot yield it — a backend
    key is [<folder-id>/<hash>], an escaped cache leaf is [.tsync-esc-<hash>],
    and both are one-way. Everywhere else the logical key is real-path shaped
    and already holds the answer.

    [private], so the record cannot be built or functionally updated from
    outside: a name reaches disk only through a writer that stamps it from the
    key. *)
type t = private {
  size : int64;
  chunk_size : int;
  chunks : Chunk_table.t;
  h1 : string;
  h2 : string;
  mtime : float;
  symlink : string option;
}

(** What an upload produces per chunk. Read paths go through {!Chunk_table}. *)
type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

val chunk_key : chunk_entry -> string

(** The reverse, for a chunk kept from a previous upload. Raises
    [Invalid_argument] for a key that is not ["<h1>-<h2>"]. *)
val entry_of_key : index:int -> size:int -> string -> chunk_entry

(** {2 Grouping}

    How a manifest's stored chunks fall into cache chunks. Derived from the
    file's {i own} [chunk_size] and the domain's cache chunk size, so a file
    uploaded under a different setting still groups correctly. {!Make} binds the
    domain's size for callers inside a functor. *)

val per : cache_chunk_size:int -> t -> int
val groups : cache_chunk_size:int -> t -> Chunk_group.t list
val group_at : cache_chunk_size:int -> t -> int -> Chunk_group.t option
val group_count : cache_chunk_size:int -> t -> int

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
  t

(** A chunkless manifest representing a symlink to [target]. *)
val make_symlink : name:string -> target:string -> mtime:float -> t

val of_string : string -> t

(** Map a sidecar: chunk keys stay in the page cache rather than the heap. *)
val of_file : string -> t

(** The name recorded in the body. Meaningful only where the location cannot
    yield one; a caller holding a key wants {!Make.name_of} instead. *)
val recorded_name : t -> string

(** Encoding needs a name, so every caller states which one. The two that
    deliberately file a manifest under a key that does not describe it — a
    version snapshot, a trashed marker — are then visible as the only ones
    passing something other than the key's own leaf. *)
val to_string : name:string -> t -> string

(** Where a chunk of a locally edited file has its bytes. *)
type slot =
  | Staged of string  (** a staged body, named by this uuid *)
  | Inherit  (** the published manifest's entry at the same index *)
  | Zero  (** a hole from a grow: reads as zeros, occupies no disk *)

(** A file with unsynced local edits. [s_size] is authoritative, not derived
    from a file length, so a truncate is a metadata write plus at most one
    boundary fixup. Presence on disk means an upload is owed; once [s_published]
    is set the upload has published and only a promotion remains. *)
type staged = {
  s_name : string;
  s_size : int64;
  s_mtime : float;
  s_chunk_size : int;
  s_slots : slot array;
  s_whole : string option;
      (** A whole file handed over by a frontend: one file rather than per-chunk
          bodies, [s_slots] empty. The upload reads it directly, so adopting one
          costs a rename, not a copy. *)
  s_published : t option;
}

(** Chunk count of a file of [size] at [chunk_size]; 0 for an empty file. *)
val num_chunks_for : int64 -> int -> int

(** Bytes chunk [i] holds in a file of [size] at [chunk_size]. *)
val chunk_len : size:int64 -> chunk_size:int -> int -> int

(** A fresh staged-body id. *)
val new_uuid : unit -> string

(** True when [key] has unsynced edits, or the chunk store holds every cache
    chunk its sidecar's chunks group into. Synchronous, for the CLI listing;
    [false] for a partly cached file. *)
val is_local : Conf.locality -> string -> bool

(** The local manifest mirror for one domain: where manifests live, how the tree
    is walked, and the parsed-sidecar cache. Callers name logical keys only — no
    cache paths, no domain prefixes, no raw bodies. *)
module Make (C : Conf.S) : sig
  (** {2 Grouping}

      {!Manifest.per} and friends with the domain's cache chunk size applied. *)

  val per : t -> int
  val groups : t -> Chunk_group.t list
  val group_at : t -> int -> Chunk_group.t option

  (** For the staged path, whose inherited chunks come from a published manifest
      that may not exist: no base means nothing to inherit. *)
  val group_at_opt : t option -> int -> Chunk_group.t option

  val groups_opt : t option -> Chunk_group.t list

  (** On-disk path of [key]'s sidecar. Its inode doubles as the existence and
      directory test, since directories exist only in this tree. *)
  val path : string -> string

  (** [key]'s manifest, parsed and cached. [None] when absent or unparseable. *)
  val read : string -> t option Lwt.t

  (** The name a manifest at [key] has. The location answers whenever it can;
      the body is consulted only for an escaped on-disk leaf, which is the one
      case a path cannot express. The file counterpart of [real_dir_name]. *)
  val name_of : key:string -> t -> string

  (** Writes [t] under [key], recording the name [key] encodes. A caller cannot
      file a manifest under one name and have it record another. *)
  val write : string -> t -> unit Lwt.t

  val delete : string -> unit Lwt.t
  val rename : src_key:string -> dst_key:string -> unit Lwt.t
  val create_dir : string -> unit Lwt.t
  val delete_dir : string -> unit Lwt.t

  (** Immediate children of [prefix]: file entries (logical keys, size, mtime)
      and real subdirectory names. The one directory listing there is, serving
      both readdir and frontend enumeration. Internal markers are filtered,
      names are real rather than escaped, and a staged file's own size and mtime
      win — it is listed even when nothing of it has been published. *)
  val list_children :
    prefix:string -> unit -> (Backend.file_entry list * string list) Lwt.t

  (** Every file entry under [prefix], recursively. *)
  val list_tree : prefix:string -> unit -> Backend.file_entry list Lwt.t

  (** Domain-relative real path of every file the domain holds locally,
      published or only staged (unsorted). *)
  val walk : unit -> string list Lwt.t

  (** [key]'s content, staged edits winning over what was last published, with
      the published manifest alongside for inherited chunks. The single
      resolution point: no caller decides this itself. *)
  val resolve :
    string -> [ `Staged of staged * t option | `Published of t ] option Lwt.t

  val read_staged : string -> staged option Lwt.t
  val write_staged : string -> staged -> unit Lwt.t
  val delete_staged : string -> unit Lwt.t
  val staged_exists : string -> bool Lwt.t
  val rename_staged : src_key:string -> dst_key:string -> unit Lwt.t

  (** Logical keys of every file owing an upload. *)
  val list_staged : unit -> string list Lwt.t

  (** Uuids of every staged body some staged manifest names. *)
  val staged_uuids : unit -> string list Lwt.t

  (** Remove empty directories left in the staged manifest tree. *)
  val prune_staged_dirs : unit -> unit Lwt.t

  (** Whether the mirror exists, i.e. this domain has a local cache. *)
  val mirror_exists : unit -> bool Lwt.t

  (** Create the mirror root and drop leftover temp files. *)
  val init : unit -> unit Lwt.t
end
