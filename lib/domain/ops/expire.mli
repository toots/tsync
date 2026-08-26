(** Drop the references that keep old content alive: version history, trashed
    folders, and the journal.

    [cutoff] governs all three — each is deleted when its timestamp predates it.
    What this leaves behind is chunks nothing points at any more, which is
    {!Gc}'s job: the two are separate commands because only some stores can do
    the second.

    Trimming the journal by age means a client offline for longer than the
    retention window must resync rather than catch up incrementally — which is
    already true of the versions and trashed files it missed.

    Works on every backend: nothing here needs more of a store than deleting a
    key. *)

type stats = { versions_deleted : int; journal_deleted : int }

(** Walking the backend's folder tree, which is how a whole domain is reached
    from its root. *)
module type TREE = sig
  type 'a io
  type pool

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
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

(** How far this client has read the shared journal. *)
module type CURSOR = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val fetch_cursor : unit -> Journal.Entry_key.t option io
  end
end

module Over
    (Io : Io.S)
    (_ : TREE with type 'a io := 'a Io.t)
    (_ : CURSOR with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** Delete one trashed folder and everything under it, now, answering how
        many objects went. [`Not_in_trash] when [path] names nothing there.

        Separate from {!expire} because age is the only handle that one has, and
        one cutoff governs versions and the journal alongside the trash.

        Leaves chunks nothing points at any more, which is {!Gc}'s job. *)
    val purge_trashed :
      ?on_delete:(name:string -> deleted:int -> unit) ->
      path:string ->
      unit ->
      [ `Purged of int | `Not_in_trash ] Io.t

    (** [expire ~cutoff ()] empties trashed folders, then deletes versions and
        journal entries older than [cutoff] (seconds since the epoch). Reads and
        deletions both go through {!Conf.store}, so they reach every configured
        store.

        [name] is the namespace being worked on — "trash", "versions" or
        "journal". [on_list] fires before listing one, [on_scan] once its size
        is known, and [on_delete] per batch of deletions with the running total.
    *)
    val expire :
      ?on_list:(name:string -> unit) ->
      ?on_scan:(name:string -> objects:int -> unit) ->
      ?on_delete:(name:string -> deleted:int -> unit) ->
      cutoff:float ->
      unit ->
      stats Io.t
  end
end
