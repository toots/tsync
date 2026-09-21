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

module type S = History_intf.S

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = History_intf.OVER

module Over (Io : Io.S) (_ : Clock.S with type 'a io := 'a Io.t) : sig
  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (L : Layout.S with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t
end
