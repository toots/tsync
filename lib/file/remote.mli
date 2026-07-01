exception Cancelled

module Make (C : Conf.S) : sig
  val upload :
    key:string ->
    src_path:string ->
    mtime:float ->
    ?cancel:bool Atomic.t ->
    unit ->
    Manifest.state

  (** Download [key] to [dst_path] from the primary backend. Returns
      [Some state] if the object is a chunked manifest, [None] for plain
      objects. *)
  val download : key:string -> dst_path:string -> Manifest.state option
end
