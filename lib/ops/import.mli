(** Import a folder of existing data into a domain: upload every file to all
    backends (chunked, deduplicated), write manifest sidecars, and publish a
    journal entry so other clients converge. No file data is cached locally:
    imported files read as not cached and are fetched on demand.

    Symlink handling is controlled by [C.symlink_policy]:
    - [`Keep] — store as a first-class symlink object (chunkless manifest)
    - [`Follow] — dereference and upload the target's content; broken links
      skipped
    - [`Skip] — skip all symlinks and count them in the summary *)

type status =
  | Imported of int64  (** uploaded; payload is the logical size *)
  | Skipped_exists  (** key already in the domain (sidecar or remote) *)
  | Skipped_symlink  (** symlink skipped per policy (skip) or broken (follow) *)
  | Failed of string  (** upload failed; payload is the error message *)

type summary = {
  imported : int;
  skipped : int;
  skipped_symlinks : int;
  failed : int;
}

module Make (C : Conf.S) : sig
  (** Import every file under [src] (recursively, sorted), calling [on_file] per
      entry. Directories are created in the manifest tree and on the backends.
      When [force_rehash] is true, existing keys are not skipped: every file is
      re-hashed, missing or changed chunks are re-uploaded, and the manifest is
      republished. When [only] is non-empty, only entries matching one of its
      globs are imported; [exclude] is then applied on top of that set.

      [on_plan] fires once the set to import is known, [on_start] as each entry
      is picked up, and [on_file] once it is done. A caller wanting to say what
      the import is working on wants [on_start]: an entry spends its whole life
      between the two, and a large file spends hours there. *)
  val run :
    ?only:string list ->
    ?exclude:string list ->
    ?force_rehash:bool ->
    ?on_dir:(rel:string -> unit) ->
    ?on_plan:(files:int -> unit) ->
    ?on_start:(rel:string -> unit) ->
    src:string ->
    on_file:(rel:string -> status -> unit) ->
    unit ->
    summary Lwt.t
end
