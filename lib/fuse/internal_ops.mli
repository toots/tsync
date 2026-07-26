(** The real filesystem operations: every path maps to a domain key and is
    served by {!File}. There is no OS handle to bracket — reads and writes
    address chunk bodies, not one assembled file — so a handle's whole lifetime
    is [fopen] deciding what a create or truncate means and [release] queueing
    the upload a staged file owes. *)
module Make (F : File.S) : sig
  val make : fuse_to_key:(string -> string) -> Path_ops.t
end
