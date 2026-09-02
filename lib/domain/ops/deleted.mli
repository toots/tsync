(** Files the domain has versions of but does not hold.

    A deletion leaves the versions behind — that is what makes it recoverable —
    so what names a deleted file is a version key with nothing live under it.
    Both of these walk {!Conf.S.versions_prefix} and ask the store whether the
    live key is still there.

    The paths are what a version body recorded, not what its key spells: a
    version key carries a hash of the folder id and leaf, which is one way only.

    An {!entry}'s [latest] is the newest version's timestamp, in the units the
    key carries. *)
type entry = { path : string; latest : int64; versions : int }

module Over (Io : Io.S) (_ : Folder_ids.S with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** Deleted files directly under the folder at domain-relative [rel], by
        name. Mints a folder id if this client has none, since a listing of
        somewhere that does not resolve is empty rather than wrong. *)
    val in_folder : Logical_key.t -> string list Io.t

    (** Every deleted file in the domain, unordered — one listing of the whole
        versions prefix, then one existence check per distinct file. *)
    val in_domain : unit -> entry list Io.t
  end
end
