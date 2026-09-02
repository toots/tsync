(** The local index of which directory carries which id, and the cache tree
    beside it — both rebuilt from what the walk finds. *)
module type FOLDER_IDS = sig
  type 'a io

  val write :
    cache_root:string ->
    domain_name:string ->
    Logical_key.t ->
    Folder.marker ->
    unit io
end

module type CACHE = sig
  type 'a io

  val clear : cache_root:string -> domain_name:string -> unit io
end

(** Bringing this client's view of a domain back in line with the store.

    Two ways, and the choice between them is the point: apply the journal
    entries published since the local bookmark, or — when there is no bookmark,
    when the journal cannot carry one to now, or when the caller insists — clear
    the cache and rebuild the manifest mirror by walking the folder tree whole.

    One pass of the same engine the daemon polls with, so the two cannot drift
    apart. *)

type outcome =
  | Full of { manifests : int; failed : int; reason : string }
      (** [reason] is why a full rebuild was chosen, for a caller that reports
          it. [failed] counts children that could not be read or classified; a
          rebuild that did not reach everything leaves the bookmark alone. *)
  | Incremental of { applied : int }

(** Where a long run has got to, for a caller reporting on it. There is no
    total: the folder tree is discovered as it is walked, so a denominator would
    be one this cannot know. *)
type progress = {
  on_phase : string -> unit;
  on_current : string option -> unit;
      (** The folder being walked, [None] once the walk is done. *)
}

(** Walking the backend's folder tree, which is how a whole domain is reached
    from its root. *)
module type TREE = sig
  type 'a io
  type pool

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val children :
      ?on_unusable:Inode_tree.on_unusable ->
      ?refresh_index:bool ->
      ?on_index:(Stored_key.t -> unit) ->
      ?slots:pool ->
      folder_id:string ->
      unit ->
      Inode_tree.entry list io

    val fold_tree :
      ?on_unusable:Inode_tree.on_unusable ->
      ?refresh_index:bool ->
      ?on_index:(Stored_key.t -> unit) ->
      ?slots:pool ->
      folder_id:string ->
      key:Logical_key.t ->
      ('a -> Logical_key.t -> Inode_tree.entry -> 'a io) ->
      'a ->
      'a io
  end
end

(** The local mark on the shared journal, and the entries behind it. *)
module type CURSOR = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val read_last_sync_key : unit -> Journal.Entry_key.t option
    val write_last_sync_key : Journal.Entry_key.t -> unit

    val list_journal_keys :
      ?start_after:Journal.Entry_key.t -> unit -> Journal.Entry_key.t list io

    val flush_cursor : unit -> unit io
  end
end

(** Writing a manifest into the local mirror, which is what a resync rebuilds,
    and the record half a queue drains. *)
module type CHECKOUT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    include File.Owing with type 'a io := 'a io
    include File_ops.S with type 'a io := 'a io

    val write_manifest : Logical_key.t -> Manifest.t -> unit io
  end
end

(** The two directions of the journal: what a peer left to apply, and what this
    client left to finish. *)
module type SYNC = sig
  type 'a io

  module Queue
      (_ : Conf.S with type 'a io = 'a io)
      (_ : File.Owing with type 'a io := 'a io) : sig
    val start : on_upload_done:(key:Logical_key.t -> unit io) -> unit
    val drain : unit -> unit io
  end

  module Replay
      (_ : Conf.S with type 'a io = 'a io)
      (_ : File_ops.S with type 'a io := 'a io) : sig
    val reconcile : unit -> unit io
    val apply_foreign : on_changed:(string -> unit) -> unit -> int io
  end
end

(** Where a folder's child is filed in the working copy: shared with the browse
    path, so a resync and a browse leave the same tree behind. *)
module type FILING = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val record : parent:Logical_key.t -> Inode_tree.entry -> Logical_key.t io
  end
end

module Over
    (Io : Io.S)
    (_ : FOLDER_IDS with type 'a io := 'a Io.t)
    (_ : CACHE with type 'a io := 'a Io.t)
    (Pools : Bounded.S with type 'a io := 'a Io.t)
    (_ : TREE with type 'a io := 'a Io.t and type pool := Pools.t)
    (_ : CURSOR with type 'a io := 'a Io.t)
    (_ : CHECKOUT with type 'a io := 'a Io.t)
    (_ : FILING with type 'a io := 'a Io.t)
    (_ : SYNC with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** [notify] is called once the rebuild is complete and never before, or a
        daemon told earlier re-reads a mirror that is still being written.
        [on_decision] receives the local mark, the published journal and why a
        rebuild was chosen (or [None] for an incremental pass), once that is
        settled and before anything acts on it.

        [full] forces a rebuild that the bookmark would not have required.
        [parallelism] bounds the concurrent backend reads of the walk. *)
    val run :
      ?full:bool ->
      ?progress:progress ->
      ?on_manifest:(string -> unit) ->
      ?on_decision:
        (Journal.Entry_key.t option ->
        Journal.Entry_key.t list ->
        string option ->
        unit) ->
      parallelism:int ->
      notify:(unit -> unit) ->
      unit ->
      outcome Io.t

    (** How far this client has applied the shared journal, for a caller that
        reports it without running a pass. *)
    val bookmark : unit -> Journal.Entry_key.t option

    val client_uuid : unit -> string
  end
end
