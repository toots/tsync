type put_data = {
  key : string;
  src_path : string;
  entry_key : string;
  ops : Journal.op list;
}

type event = Put of put_data
type t

(** Create the upload queue and start 4 worker domains. [upload] and [evict] are
    called by workers after a completed upload. [on_version] is called after
    each successfully committed journal entry. [on_upload_done] is called after
    a local cache file is auto-evicted. *)
val make :
  store:File_store.t ->
  upload:(key:string -> cancel:bool Atomic.t -> unit) ->
  on_version:(entry_key:string -> unit) ->
  on_upload_done:(key:string -> unit) ->
  t

(** Enqueue a [Put] for async upload. If an upload for the same key is already
    running, it is cancelled and the new one queued as pending. *)
val post : t -> event -> unit

(** Cancel any in-flight [Put] for [key]. Returns [true] if an upload was
    running. *)
val cancel_put : t -> string -> bool

(** Signal workers to stop and wait for all queued uploads to finish. *)
val drain : t -> unit
