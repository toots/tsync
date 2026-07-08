(** Import a folder of existing data into a domain: upload every file to all
    backends (chunked, deduplicated), write manifest sidecars in the local
    cache, and publish a journal entry so other clients converge. The data is
    not copied into the cache — the cache data path is a symlink to the source
    file, so imported files read as cached; evicting one removes the link. *)

type status =
  | Imported of int64  (** uploaded; payload is the file size *)
  | Skipped_exists  (** key already in the domain (sidecar or remote) *)

type summary = { imported : int; skipped : int }

module Make (C : Conf.S) : sig
  (** Import every file under [src] (recursively, sorted), calling [on_file] per
      file. Directories are created in the manifest tree and on the backends.
      Existing keys are never overwritten. *)
  val run :
    ?exclude:string list ->
    src:string ->
    on_file:(rel:string -> status -> unit) ->
    unit ->
    summary Lwt.t
end
