type put_data = {
  key : string;
  src_path : string;
  entry_key : string;
  ops : Journal.op list;
}

type event =
  | Put of put_data
  | Delete of { key : string; entry_key : string; ops : Journal.op list }
  | Rename of {
      src_key : string;
      dst_key : string;
      src_is_dir : bool;
      dst_local_path : string;
      entry_key : string;
      put_ops : Journal.op list;
      rename_ops : Journal.op list;
    }
  | Mkdir of { key : string; entry_key : string; ops : Journal.op list }
  | Rmdir of { key : string; entry_key : string; ops : Journal.op list }
  | Evict of { key : string }

type t

(** Create the sync queue and start 4 upload worker domains. [on_version] is
    called after each successfully committed journal entry. [on_evict] is called
    after a local cache file is evicted. *)
val make :
  store:File_store.t ->
  auto_evict:bool ref ->
  on_version:(entry_key:string -> unit) ->
  on_evict:(key:string -> unit) ->
  t

(** Dispatch a filesystem event. [Put] is enqueued to a worker domain; all other
    events execute synchronously, cancelling any in-flight [Put] for the
    affected key(s) first. *)
val post : t -> event -> unit

(** Cancel any in-flight [Put] for [key]. Returns [true] if an upload was
    running. *)
val cancel_put : t -> string -> bool

(** Signal workers to stop and wait for all queued uploads to finish. *)
val drain : t -> unit
