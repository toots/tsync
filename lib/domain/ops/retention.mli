(** What keeps old content reachable, and dropping it: the trashed folders, the
    versions a deleted file left behind, and the journal.

    A removed folder's marker is moved under {!Stored_key.trash_id}, unreachable
    from the root, so its subtree leaves listings and resync without anything
    being copied or deleted; restoring is the same move in reverse. A deleted
    file is a version key with nothing live under it. Both and the journal are
    dropped by {!Over.Make.expire} under one cutoff, which leaves chunks nothing
    points at any more: that is {!Gc}'s job, a separate command because only
    some stores can do it.

    Trimming the journal by age means a client offline for longer than the
    retention window must resync rather than catch up incrementally, which is
    already true of the versions and trashed files it missed. Nothing here
    records a journal entry, so a peer learns of a restore by resyncing. *)

type stats = { versions_deleted : int; journal_deleted : int }

type restored =
  | Restored
  | Not_in_trash
  | Parent_unknown
      (** The folder is there, but this client has no id recorded for the parent
          it would go back under, so there is no key to write. A sync resolves
          the parent and makes the restore possible. *)

(** A file the domain has versions of but does not hold. [path] is what the
    newest version body recorded, since a version key carries a hash of the
    folder id and leaf; [latest] is that version's timestamp in the units the
    key carries. *)
type deleted = { path : string; latest : int64; versions : int }

module Over
    (Io : Io.S)
    (_ : Layout.OVER with type 'a io := 'a Io.t)
    (_ : Store.OVER with type 'a io := 'a Io.t)
    (_ : Folder_ids.S with type 'a io := 'a Io.t)
    (_ : Inode_tree.OVER with type 'a io := 'a Io.t)
    (_ : File_store.OVER with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** The domain-relative path of every trashed folder. A marker whose body
        does not name one is passed over: a body that will not parse is a write
        in flight, not a finding. *)
    val trashed : unit -> string list Io.t

    (** Put [path] back where it was. The subtree is untouched. *)
    val restore : string -> restored Io.t

    (** Delete one trashed folder and everything under it, now, answering how
        many objects went. [`Not_in_trash] when [path] names nothing there. *)
    val purge_trashed :
      ?on_delete:(name:string -> deleted:int -> unit) ->
      path:string ->
      unit ->
      [ `Purged of int | `Not_in_trash ] Io.t

    (** Deleted files directly under the folder at [key], by name. Mints a
        folder id if this client has none, since a listing of somewhere that
        does not resolve is empty rather than wrong. *)
    val deleted_in_folder : Logical_key.t -> string list Io.t

    (** Every deleted file in the domain, unordered: one listing of the whole
        versions prefix, then one existence check per distinct file. *)
    val deleted_in_domain : unit -> deleted list Io.t

    (** [expire ~cutoff ()] empties trashed folders, then deletes versions and
        journal entries older than [cutoff] (seconds since the epoch). Reads and
        deletions both go through {!Conf.store}, so they reach every configured
        store.

        [name] is the namespace being worked on: "trash", "versions" or
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
