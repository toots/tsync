(** Manifest-level backend access, keyed by logical keys.

    A logical key becomes a backend key through the {!Layout} scheme, so no
    caller here or above ever constructs one. Everything goes through
    {!Conf.store}, which is what fans a write out and orders a read. Chunk,
    journal and cursor objects are not manifest keys and live in {!File_store}
    and {!Remote}. *)

module Make (C : Conf.S) (L : Layout.S) : sig
  (** Publish a manifest, bringing its folder into existence if needed. Every
      other operation here resolves what is already there and treats an unknown
      folder as absent. *)
  val put_manifest : key:string -> data:Chunk.t -> unit Lwt.t

  val get_manifest_opt : key:string -> string option Lwt.t

  (** {!get_manifest_opt} saying which nothing it found: [`Absent] is the
      store's answer about the domain, while [`Unresolved] is this client not
      knowing the key's folder yet and says nothing about what the store holds.
      For a caller that remembers an answer — the two are not equally
      rememberable, one changing without the domain changing. *)
  val get_manifest_state :
    key:string -> [ `Body of string | `Absent | `Unresolved ] Lwt.t
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
      key, when the backend has one. Best-effort: a lost snapshot must not wedge
      the write it precedes. *)
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

  (** Bodies of several at once, in one request where the store has a way to
      make one and a bounded fan-out where it has not. [None] for a key the
      store no longer holds, a listing and the reads that follow it not being
      one act. Sizes come from the listing that produced [entries], which is
      what lets a request be packed to a byte budget. *)
  val get_objects :
    ?slots:Lwt_bounded.t ->
    entries:Backend.file_entry list ->
    unit ->
    (string * string option) list Lwt.t
  val put_raw : bkey:string -> data:string -> unit Lwt.t
  val delete_raw : bkey:string -> unit Lwt.t
end
