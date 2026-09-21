(** This client's working copy of the domain: every manifest the store has,
    filed under the file's real path so the tree can be walked without it, and
    over the top of that whatever {!Staged_manifest} says this client has
    changed.

    The published half is a projection — a resync's walk rewrites it in place
    and {!S.sweep_stale} drops what the walk did not reach — which is why the
    staged half it reads through is a store of its own. This module is where the
    two are put together: it owns the published tree, and the overlay is the
    only thing that consults both. *)

include module type of struct
  include Checkout_intf
end

val availability : Conf.locality -> Logical_key.t -> availability

(** The wire and listing spelling: [online-only], [cached] or [pinned]. *)
val availability_name : availability -> string

module Over
    (Io : Io.S)
    (Fs : Cache_layout.FS with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : Manifests.OVER with type 'a io := 'a Io.t)
    (_ : Staged_manifest.OVER with type 'a io := 'a Io.t)
    (_ : Folder_ids.S with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t
