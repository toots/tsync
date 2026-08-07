(** Manifest-level backend access, keyed by logical keys.

    A logical key becomes a backend key through the {!Layout} scheme, so no
    caller here or above ever constructs one. Writes fan out to every configured
    backend; reads go to the primary. Chunk, journal and cursor objects are not
    manifest keys and live in {!File_store} and {!Remote}. *)

module Make (C : Conf.S) (L : Layout.S) : sig
  (** The backend every read goes to. *)
  val primary : unit -> (module Backend.S)

  (** Publish a manifest, bringing its folder into existence if needed. Every
      other operation here resolves what is already there and treats an unknown
      folder as absent. *)
  val put_manifest : key:string -> data:string -> unit Lwt.t

  val get_manifest_opt : key:string -> string option Lwt.t
  val head_manifest : key:string -> Backend.file_entry option Lwt.t
  val delete_manifest : key:string -> unit Lwt.t

  (** Move a manifest. The destination may be brought into existence; the source
      has to be there already or there is nothing to move. *)
  val copy_manifest : src_key:string -> dst_key:string -> unit Lwt.t

  (** [<versions_prefix>/<manifest key tail>/], so a file's versions share its
      identity — a stable folder id — and survive a rename of any folder above
      it. [None] when the key's folder is unknown. *)
  val version_dir : key:string -> string option Lwt.t

  (** Snapshot the current manifest object under a fresh timestamped version
      key, when the backend has one. Best-effort: the source is only checked on
      the primary, so a replica that never received it fails the copy — and a
      lost snapshot must not wedge the write it precedes. *)
  val save_version : key:string -> unit Lwt.t

  val list_versions : key:string -> Backend.file_entry list Lwt.t
  val get_version : vkey:string -> string Lwt.t

  (** Record a directory under its parent's namespace, so a resync can rebuild
      the tree. A no-op for a layout with no folder tree. *)
  val put_folder_marker : key:string -> unit Lwt.t

  (** {2 By backend key}

      Resync walks the inode tree by folder id and already holds backend keys,
      so these take one directly rather than going through the layout. *)

  val list_namespace : folder_id:string -> Backend.file_entry list Lwt.t
  val get_object : bkey:string -> string Lwt.t
  val put_raw : bkey:string -> data:string -> unit Lwt.t
  val delete_raw : bkey:string -> unit Lwt.t
end
