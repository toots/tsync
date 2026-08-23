(** The FUSE kernel's [.fuse_hidden*] files, created when a file with open
    descriptors is renamed. They are kernel-internal and never published, so
    they live as plain files under the domain's scratch tree. *)
module Make (C : Conf.S) : sig
  val make : fuse_to_key:(string -> Logical_key.t) -> Path_ops.t
end
