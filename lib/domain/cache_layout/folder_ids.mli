(** Client-side folder-inode resolution, both ways round.

    Every folder in the local mirror carries a {!marker_name} file holding its
    stable backend id and its real name — the on-disk name may be escaped — in
    the same [{dir,name,id}] JSON as a backend folder marker ({!Folder}).

    The markers are filed under the path and so cannot answer id to path: each
    is mirrored by an entry under {!Cache_layout.folders_dir} holding the
    folder's parent id and real name, climbed to the root.

    Naming a folder goes through {!Store.S.ensure_folder_id} and so through
    {!Over.Make.write}, which writes the entry with the marker: whichever
    process writes the mirror keeps the index with it. A resync's walk rewrites
    both, and restating the index from the markers alone is
    {!Over.Make.rebuild}. *)

module type S = Folder_ids_intf.S

module Over (Io : Io.S) (_ : Fs.S with type 'a io := 'a Io.t) :
  S with type 'a io := 'a Io.t
