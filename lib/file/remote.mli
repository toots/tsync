exception Cancelled

module Make (C : Conf.S) : sig
  val upload :
    key:string ->
    src_path:string ->
    mtime:float ->
    ?cancel:bool Atomic.t ->
    unit ->
    Manifest.state Lwt.t

  (** Download chunks described by [manifest] to [dst_path], without fetching
      the manifest key itself. Used when the manifest is already known locally
      (evicted files, conflict copies). *)
  val download_chunks : dst_path:string -> Manifest.t -> unit Lwt.t

  (** Fetch only the manifest for [key] from the primary backend. Returns [None]
      if the key does not exist or is not a manifest. *)
  val fetch_manifest : key:string -> unit -> Manifest.state option Lwt.t

  (** Download [key] to [dst_path] from the primary backend. Returns
      [Some state] if the object is a chunked manifest, [None] for plain
      objects. *)
  val download : key:string -> dst_path:string -> Manifest.state option Lwt.t
end
