(** The real filesystem operations: every path maps to a domain key and is
    served by {!File}. There is no OS handle to bracket, reads and writes
    addressing chunk bodies rather than one assembled file, so a handle's whole
    lifetime is [fopen] deciding what a create or truncate means and [release]
    queueing the upload a staged file owes. *)
module Make (F : File_ops.S) : sig
  val make : fuse_to_key:(string -> F.t) -> Path_ops.t
end
