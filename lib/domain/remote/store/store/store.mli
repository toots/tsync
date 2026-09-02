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

module type S = sig
  type 'a io
  type pool

  (** Publish a manifest, bringing its folder into existence if needed. Every
      other operation here resolves what is already there and treats an
      unknown folder as absent. *)
  val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit io

  (** A manifest, or which nothing it found: [`Absent] is the store's answer
      about the domain, while [`Unresolved] is this client not knowing the
      key's folder yet and says nothing about what the store holds. For a
      caller that remembers an answer — the two are not equally rememberable,
      one changing without the domain changing. *)
  val get_manifest_state :
    key:Logical_key.t -> [ `Body of string | `Absent | `Unresolved ] io

  val head_manifest : key:Logical_key.t -> Backend.file_entry option io
  val delete_manifest : key:Logical_key.t -> unit io

  (** Move a manifest. The destination may be brought into existence; the
      source has to be there already or there is nothing to move. *)
  val copy_manifest :
    src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io

  (** Record a directory under its parent's namespace, so a resync can rebuild
      the tree. A no-op for a layout with no folder tree. *)
  val put_folder_marker : key:Logical_key.t -> unit io

  (** {2 By backend key}

      Resync walks the inode tree by folder id and already holds backend keys,
      so these take one directly rather than going through the layout. *)

  val list_namespace : folder_id:string -> Backend.file_entry list io
  val get_object : bkey:Stored_key.t -> string io

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

  val put_raw : bkey:Stored_key.t -> data:string -> unit io
  val delete_raw : bkey:Stored_key.t -> unit io
end

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = sig
  type 'a io
  type pool

  module Make
      (C : Conf.S with type 'a io = 'a io)
      (L : Layout.S with type 'a io := 'a io) : S with type 'a io := 'a io and type pool = pool
end

(** {!OVER} with the key scheme chosen, for a consumer holding real paths. *)
module type INODE = sig
  type 'a io
  type pool

  module Make (_ : Conf.S with type 'a io = 'a io) :
    S with type 'a io := 'a io and type pool = pool
end

module Over (Io : Io.S) (Batched : BATCHED with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t and type pool = Batched.pool
