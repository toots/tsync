module Make (F : File.S) : sig
  val make : fuse_to_key:(string -> string) -> Path_ops.t
end
