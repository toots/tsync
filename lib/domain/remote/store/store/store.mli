(** Manifest-level backend access, keyed by logical keys.

    A logical key becomes a backend key through the {!Layout} scheme, so no
    caller here or above ever constructs one. Everything goes through
    {!Conf.store}, which is what fans a write out and orders a read. Chunk,
    journal and cursor objects are not manifest keys and live in {!File_store}
    and {!Remote}. *)

(** The batched read a store may have of its own, already resolved: which
    drivers have one and how wide the fan-out is are settled where the stores
    are built, not here. *)
module type BATCHED = sig
  type 'a io
  type pool

  module Make (_ : Backend.S with type 'a io := 'a io) : sig
    val get_many :
      ?slots:pool ->
      entries:Backend.file_entry list ->
      unit ->
      (Stored_key.t * Bigstring.t option) list io
  end
end

(** One folder as {!S.list_many} answers it. *)
type listed_folder = {
  folder_id : string;
  listed : Backend.file_entry list;
  bodies : (Stored_key.t * string option) list;
}

module type S = sig
  type 'a io
  type pool

  (** Publish a manifest, bringing its folder into existence if needed. Every
      other operation here resolves what is already there and treats an unknown
      folder as absent. *)
  val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit io

  (** A manifest, or which nothing it found: [`Absent] is the store's answer
      about the domain, while [`Unresolved] is this client not knowing the key's
      folder yet and says nothing about what the store holds. For a caller that
      remembers an answer — the two are not equally rememberable, one changing
      without the domain changing. *)
  val get_manifest_state :
    key:Logical_key.t -> [ `Body of string | `Absent | `Unresolved ] io

  val head_manifest : key:Logical_key.t -> Backend.file_entry option io
  val delete_manifest : key:Logical_key.t -> unit io

  (** Move a manifest. The destination may be brought into existence; the source
      has to be there already or there is nothing to move. *)
  val copy_manifest : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io

  (** A directory's id, claimed on the store for it and any ancestor this client
      holds none for. For a caller entitled to bring a folder into existence:
      the local marker a claim records re-creates the directory the key names.
  *)
  val ensure_folder_id : Logical_key.t -> string io

  (** Make sure the store files the folder under its name, and its ancestors
      under theirs, answering [`Taken] with the id of another folder holding the
      name. A taken ancestor is a transient failure: its own queued creation
      moves it aside. [id] is the folder's own when the caller holds it; a
      folder this client holds no id for takes the store's, unless it named one
      at that path before, which is a folder moved or removed since. *)
  val claim_folder :
    ?id:string -> Logical_key.t -> [ `Held | `Taken of string ] io

  (** {!claim_folder}, failing transiently when another folder holds the name:
      its own queued creation moves it aside, and the caller is retried. *)
  val ensure_claimed : Logical_key.t -> unit io

  (** Record a directory under its parent's namespace, so a resync can rebuild
      the tree, its anchor written first so a marker left behind elsewhere is
      stale from this moment. A no-op for a layout with no folder tree. *)
  val put_folder_marker : key:Logical_key.t -> unit io

  (** Where a folder lives, by its id: see {!Folder.anchor}. *)
  val put_anchor : folder_id:string -> parent:string -> name:string -> unit io

  (** [None] for a folder written before anchors were, which is taken at its
      marker's word. *)
  val get_anchor : folder_id:string -> Folder.anchor option io

  (** Where the store files a folder by its anchor, against the place [at].
      [`Unanchored] for a folder written before anchors were, or one never
      published. *)
  val placed :
    folder_id:string ->
    at:Folder.anchor ->
    [ `Here | `Elsewhere of Folder.anchor | `Unanchored ] io

  (** The folder a marker on the store names, [None] when there is none. A store
      that cannot answer raises instead, so an outage is not read as a free
      name. *)
  val marker_id_at : bkey:Stored_key.t -> string option io

  (** The folder living under a name, which is what holds it against another:
      {!marker_id_at} less a marker its folder's anchor places elsewhere. *)
  val holder_at : bkey:Stored_key.t -> string option io

  (** Whether the marker at [bkey] is where its folder lives. A marker the
      folder's anchor places elsewhere is one a move left behind; a folder with
      no anchor was written before anchors were, and is taken at its marker's
      word. *)
  val filed :
    bkey:Stored_key.t ->
    Folder.marker ->
    [ `Here | `Elsewhere of Folder.anchor ] io

  (** {2 By backend key}

      Resync walks the inode tree by folder id and already holds backend keys,
      so these take one directly rather than going through the layout. *)

  val list_namespace : folder_id:string -> Backend.file_entry list io
  val get_object : bkey:Stored_key.t -> string io

  (** [None] for a key the store does not hold. *)
  val get_object_opt : bkey:Stored_key.t -> string option io

  (** Bodies of several at once, in one request where the store has a way to
      make one and a bounded fan-out where it has not. [None] for a key the
      store no longer holds, a listing and the reads that follow it not being
      one act. Sizes come from the listing that produced [entries], which is
      what lets a request be packed to a byte budget. *)
  val get_objects :
    ?slots:pool ->
    entries:Backend.file_entry list ->
    unit ->
    (Stored_key.t * string option) list io

  (** Many folders' children in one request, where the store has a way to ask
      for them: each folder's listing and the bodies of its child objects. A
      folder left out of the answer is the caller's to ask for singly. [None]
      from a store with none. *)
  val list_many :
    (folder_ids:string list -> unit -> listed_folder list io) option

  val put_raw : bkey:Stored_key.t -> data:string -> unit io

  (** Delete one object by its backend key, answering whether it was there. *)
  val delete_raw : bkey:Stored_key.t -> bool io
end

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = sig
  type 'a io
  type pool

  module Make
      (C : Conf.S with type 'a io = 'a io)
      (L : Layout.S with type 'a io := 'a io) :
    S with type 'a io := 'a io and type pool = pool
end

(** {!OVER} with the key scheme chosen, for a consumer holding real paths. *)
module type INODE = sig
  type 'a io
  type pool

  module Make (_ : Conf.S with type 'a io = 'a io) :
    S with type 'a io := 'a io and type pool = pool
end

module Over
    (Io : Io.S)
    (_ : Folder_ids.S with type 'a io := 'a Io.t)
    (Batched : BATCHED with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t and type pool = Batched.pool
