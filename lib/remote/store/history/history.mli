(** What the store keeps of a file after the live tree stopped pointing at it.

    A version is a copy of the manifest object as it stood before a write, filed
    under the same folder id the manifest itself uses — so versions survive a
    rename of the folder, and a file deleted outright leaves its versions behind
    under a key nothing live resolves. The key is built and taken apart here,
    which is the point of the module: {!parse} splits one back into its grouping
    key and timestamp, and must agree with what {!Make.version_dir} builds. *)
val parse : versions_prefix:string -> string -> (string * string) option

module Make (C : Conf.S) (L : Layout.S) : sig
  (** [<versions_prefix>/<manifest key tail>/], so a file's versions share the
      identity its manifest has. [None] for a key whose folder this client
      cannot resolve. *)
  val version_dir : key:Logical_key.t -> Stored_key.t option Lwt.t

  (** Snapshot the current manifest object under a fresh timestamped version
      key, when the backend has one. Best-effort: a lost snapshot must not wedge
      the write it precedes. *)
  val save_version : key:Logical_key.t -> unit Lwt.t

  val list_versions : key:Logical_key.t -> Backend.file_entry list Lwt.t
  val get_version : vkey:Stored_key.t -> string Lwt.t

  (** {!parse} against this domain's prefix. *)
  val parse : string -> (string * string) option
end
