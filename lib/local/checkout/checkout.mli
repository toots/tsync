(** This client's working copy of the domain.

    Each published manifest filed under the file's real path, so the tree can be
    walked without the store, and on top of it what this client has changed and
    not published. A projection apart from that staged half:
    {!Cache_layout.clear} drops everything here and a resync rebuilds it, which
    is why the staged part is the one thing it keeps. *)

(** Where a chunk of a locally edited file has its bytes: a staged body and an
    offset within it. One body holds every staged member of a cache group, so
    the offset is what separates them. It is carried rather than derived because
    the group size it would come from is configuration and can change between
    runs, while these bytes were placed once. *)
type body = { uuid : string; offset : int }

type slot =
  | Staged of body
  | Inherit  (** the published manifest's entry at the same index *)
  | Zero  (** a hole from a grow: reads as zeros, occupies no disk *)

(** The distinct bodies a slot array names, sorted. Fewer than the slots
    wherever a group shares one. *)
val body_uuids : slot array -> string list

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
  s_published : Manifest.t option;
}

(** A fresh staged-body id. *)
val new_uuid : unit -> string

(** The staged record as it is kept on disk. Versioned: a body written by a
    newer build raises rather than being read as something it is not, since what
    it describes is the only copy of unsynced work. *)
val staged_to_string : staged -> string

val staged_of_string : string -> staged

(** True when [key] has unsynced edits, or the chunk store holds every cache
    chunk its sidecar's chunks group into. Synchronous, for the CLI listing;
    [false] for a partly cached file. *)
val is_local : Conf.locality -> string -> bool

(** The local manifest mirror for one domain: where manifests live, how the tree
    is walked, and the parsed-sidecar cache. Callers name logical keys only — no
    cache paths, no domain prefixes, no raw bodies. *)
module Make (C : Conf.S) : sig
  (** On-disk path of [key]'s sidecar. Its inode doubles as the existence and
      directory test, since directories exist only in this tree. *)
  val path : string -> string

  (** [key]'s manifest, parsed and cached. [None] when absent or unparseable. *)
  val read : string -> Manifest.t option Lwt.t

  (** Manifests held from earlier reads. A cached one keeps the mapping it was
      read through, so this counts live mappings rather than bytes, and it is
      bounded. Exposed because that bound is invisible from {!read}, which
      answers the same whether it was served from the cache or the file. *)
  val memo_size : unit -> int

  (** Writes [t] under [key], recording the name [key] encodes. A caller cannot
      file a manifest under one name and have it record another. *)
  val write : string -> Manifest.t -> unit Lwt.t

  val delete : string -> unit Lwt.t
  val rename : src_key:string -> dst_key:string -> unit Lwt.t
  val create_dir : string -> unit Lwt.t
  val delete_dir : string -> unit Lwt.t

  (** Immediate children of [prefix]: file entries (logical keys, size, mtime)
      and real subdirectory names, serving both readdir and frontend
      enumeration.

      Internal markers are filtered, names are real rather than escaped, and a
      staged file's own size and mtime win — it is listed even when nothing of
      it has been published. *)
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
    string ->
    [ `Staged of staged * Manifest.t option | `Published of Manifest.t ] option
    Lwt.t

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

  (** Create the mirror root. Every process serving the domain needs this and
      nothing more. *)
  val ensure_root : unit -> unit Lwt.t

  (** That, and drop the temp files a crash left behind.

      Once per machine, before anything serves. A temp name embeds the pid that
      made it, but the recogniser does not read it back and could not usefully:
      what matters is whether some process is still writing, not which one. So a
      second process running this unlinks the first one's temp file, and its
      rename then fails ENOENT. *)
  val reap_leftovers : unit -> unit Lwt.t
end
