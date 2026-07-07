exception Cancelled

(** Outcome of rechecking one file's remote state. *)
type recheck_report = {
  chunks_total : int;
  chunks_repaired : int;  (** re-uploaded from local data *)
  chunks_unrepairable : int;  (** missing/bad remotely, no local data *)
  manifest_repaired : bool;  (** remote manifest re-published *)
  manifest_bad : bool;  (** remote manifest wrong but not repairable *)
  local_stale : bool;  (** re-hash disagreed with the local sidecar *)
}

module Make (C : Conf.S) : sig
  (** Upload [src_path] as chunks under [key]: each chunk is read, hashed (chunk
      key) and uploaded if absent, then the manifest is written. Setting
      [cancel] aborts at the next chunk boundary with {!Cancelled}. *)
  val upload :
    key:string ->
    src_path:string ->
    mtime:float ->
    ?cancel:bool ref ->
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

  (** Recheck a file whose data is in the local cache: re-hash [src_path] chunk
      by chunk, verify each chunk remotely (HEAD + size) and re-upload the wrong
      ones, then verify/republish the remote manifest. Returns the freshly
      computed manifest state so the caller can refresh the sidecar;
      [local_stale] is set when the re-hash disagrees with [sidecar]. *)
  val recheck_cached :
    key:string ->
    src_path:string ->
    mtime:float ->
    sidecar:Manifest.t ->
    unit ->
    (Manifest.state * recheck_report) Lwt.t

  (** Recheck an evicted file from its sidecar manifest: verify each chunk
      remotely (HEAD + size). Chunks cannot be repaired without local data; a
      missing/bad remote manifest is republished from the sidecar when all
      chunks check out. *)
  val recheck_evicted : key:string -> Manifest.t -> recheck_report Lwt.t
end
