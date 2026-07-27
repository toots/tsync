exception Cancelled

(** Outcome of rechecking one file's remote state. *)
type recheck_report = {
  chunks_total : int;
  chunks_repaired : int;  (** re-uploaded from local data *)
  chunks_unrepairable : int;  (** missing/bad remotely, no local data *)
  manifest_repaired : bool;  (** remote manifest re-published *)
  manifest_bad : bool;  (** remote manifest wrong but not repairable *)
}

module type S = sig
  (** Upload [src_path] as chunks under [key]: each chunk is read, hashed (chunk
      key) and uploaded if absent, then the manifest is written. For a file
      handed over whole — import, and the FileProvider's re-import. Setting
      [cancel] aborts at the next chunk boundary with {!Cancelled}. *)
  val upload :
    key:string ->
    src_path:string ->
    mtime:float ->
    chunk_size:int ->
    ?cancel:bool ref ->
    unit ->
    Manifest.state Lwt.t

  (** Fetch one chunk body from the primary backend by its content key
      ([Manifest.chunk_key], without the domain's chunk prefix). *)
  val get_chunk : chunk_key:string -> string Lwt.t

  (** Chunk size for files this client creates: [Conf.S.chunk_size] when the
      config says, else what the primary backend recommends — an http-proxy
      answers with the serving domain's own, so the setting need not be mirrored
      in two configs — else [Conf.default_chunk_size]. Asked once and memoized;
      existing files always use the size recorded in their own manifest and
      never come near this. *)
  val chunk_size : unit -> int Lwt.t

  (** Upload a file whose bytes the caller supplies per chunk, then publish its
      manifest. [source index] is either [`Reuse e] — an unchanged chunk,
      neither read nor sent, keeping entry [e] — or [`Data bytes]. Knowing
      nothing about where those bytes come from keeps local staging out of this
      module. An empty file still yields one empty chunk. [cancel] aborts at the
      next chunk boundary with {!Cancelled}, unpublishing the manifest if it
      already went. *)
  val upload_chunks :
    key:string ->
    name:string ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:(int -> [ `Reuse of Manifest.chunk_entry | `Data of string ] Lwt.t) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.state Lwt.t

  (** Fetch only the manifest for [key] from the primary backend. Returns [None]
      if the key does not exist or is not a manifest. *)
  val fetch_manifest : key:string -> unit -> Manifest.state option Lwt.t

  (** Recheck a file from its manifest: verify every chunk it names remotely
      (HEAD + size), re-uploading the wrong ones from [local_body] when the
      local chunk store has them, then republish a missing or wrong remote
      manifest when every chunk checks out. Local integrity is a separate matter
      — see {!Chunk_cache.verify}. *)
  val recheck_from_manifest :
    key:string ->
    local_body:(Manifest.chunk_entry -> string option Lwt.t) ->
    Manifest.t ->
    recheck_report Lwt.t
end

(** Keys are mapped to backend keys through [L]. Callers holding real paths want
    {!Make}; {!Layout.Identity} serves callers that already hold backend keys.
*)
module Make_with_layout (C : Conf.S) (L : Layout.S) : S

module Make (C : Conf.S) : S
