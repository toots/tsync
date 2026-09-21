module type S = sig
  type 'a io

  (** [<versions_prefix>/<manifest key tail>/], so a file's versions share the
      identity its manifest has. [None] for a key whose folder this client
      cannot resolve. *)
  val version_dir : key:Logical_key.t -> Stored_key.t option io

  (** Snapshot the current manifest object under a fresh timestamped version
      key, when the backend has one. Best-effort: a lost snapshot must not wedge
      the write it precedes. *)
  val save_version : key:Logical_key.t -> unit io

  val list_versions : key:Logical_key.t -> Backend.file_entry list io
  val get_version : vkey:Stored_key.t -> string io
end

module type OVER = sig
  type 'a io

  module Make
      (C : Conf.S with type 'a io = 'a io)
      (L : Layout.S with type 'a io := 'a io) : S with type 'a io := 'a io
end
