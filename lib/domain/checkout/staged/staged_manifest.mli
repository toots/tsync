(** What this client has changed and not published: one sidecar per file, in a
    tree keyed exactly like the published one, so a staged manifest and the
    published one it shadows sit at matching paths.

    The only copy there is. {!Cache_layout.clear} rebuilds the rest of the
    checkout from the store and leaves this tree alone, which is the whole
    reason it is a store of its own. The bytes these sidecars point at are next
    door in {!Staged_body}. *)

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
}

(** Which half of the lifecycle a sidecar is in: an upload is owed, or one has
    published and only the local promotion remains.

    What an upload published is not a field of {!staged}, so a mutation has
    nothing to clear. {!Make.write} takes the edits alone and can only produce
    [Owed]; only {!Make.commit} produces [Committed]. That is what stops a write
    from carrying a finished upload's record past the bytes it described. *)
type state = Owed of staged | Committed of staged * Manifest.t

(** The edits either way, for callers that do not care which half. *)
val edits : state -> staged

(** A fresh staged-body id. *)
val new_uuid : unit -> string

(** The staged record as it is kept on disk. Versioned: a body written by a
    newer build raises rather than being read as something it is not, since what
    it describes is the only copy of unsynced work. *)
val staged_to_string : state -> string

val staged_of_string : string -> state

(** Where the sidecar for [key] sits, for the synchronous CLI paths that hold no
    functor instance. *)
val sidecar_path :
  cache_root:string -> domain_name:string -> Logical_key.t -> string

module type S = sig
  type 'a io

  (** The staged tree's root. *)
  val root : unit -> string

  val path : Logical_key.t -> string
  val exists : Logical_key.t -> bool io

  (** [None] when nothing is staged. A sidecar that cannot be decoded is moved
      aside rather than dropped: it is unsynced user data, and the next start
      must not trip over it again. *)
  val read : Logical_key.t -> state option io

  (** {!read}, keeping only what the file holds. For the callers — the read
      path, the listings — that have no business with the lifecycle. *)
  val read_edits : Logical_key.t -> staged option io

  (** The leaf name is stamped from [key], as the published tree does, so a
      listing shows the right name before an upload lands. *)
  val write : Logical_key.t -> staged -> unit io

  (** Record what an upload published for the edits it hashed. Written before
      anything local moves, so a crash after it leaves only local work to
      replay, and the next start finishes the promotion without re-uploading.
  *)
  val commit : Logical_key.t -> staged -> Manifest.t -> unit io

  val delete : Logical_key.t -> unit io
  val rename : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io

  (** Fold over the sidecars under [rel_dir], by on-disk position: a sidecar
      records its leaf name, but where it sits is what identifies the file. *)
  val fold :
    rel_dir:string ->
    deep:bool ->
    ('a -> Logical_key.t -> staged -> 'a) ->
    'a ->
    'a io

  (** Logical keys of every file owing an upload. *)
  val list : unit -> Logical_key.t list io

  (** Uuids of every staged body some sidecar names: what a sweep of the body
      trees must keep. *)
  val uuids : unit -> string list io

  (** The staged files under [rel_dir], each with what is staged for it. A
      locally created file has no published sidecar, so the published tree
      alone would not list it; for one that does, the staged size and mtime
      are the current ones. *)
  val entries :
    rel_dir:string -> deep:bool -> (Logical_key.t * staged) list io
end

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = sig
  type 'a io

  module Make (C : Conf.S with type 'a io = 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (_ : Cache_layout.FS with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t
