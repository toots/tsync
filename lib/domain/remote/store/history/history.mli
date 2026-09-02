(** What the store keeps of a file after the live tree stopped pointing at it.

    A version is a copy of the manifest object as it stood before a write, filed
    under the same folder id the manifest itself uses — so versions survive a
    rename of the folder, and a file deleted outright leaves its versions behind
    under a key nothing live resolves. The key is built and taken apart here,
    which is the point of the module: {!parse} splits one back into its grouping
    key and timestamp, and must agree with what {!Make.version_dir} builds. *)
val parse : versions_prefix:string -> Stored_key.t -> (string * string) option

(** The other direction of {!parse}: the directory holding a grouping key's
    versions, and the manifest that key belongs to. For a caller walking the
    versions space, which meets keys before it knows what they are versions of.
*)
val versions_of : versions_prefix:string -> grouping:string -> Stored_key.t

val manifest_of : domain_prefix:string -> grouping:string -> Stored_key.t

(** Every version of every file in one folder, which share its id. *)
val folder_versions : versions_prefix:string -> folder_id:string -> Stored_key.t

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

  (** {!parse} against this domain's prefix. *)
  val parse : Stored_key.t -> (string * string) option
end

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = sig
  type 'a io

  module Make
      (C : Conf.S with type 'a io = 'a io)
      (L : Layout.S with type 'a io := 'a io) : S with type 'a io := 'a io
end

module Over (Io : Io.S) : sig
  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (L : Layout.S with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t
end
