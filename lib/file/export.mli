(** Export every file of a domain to a plain folder, reading manifests directly
    (no daemon needed). Cached files (including dirty ones) are copied from the
    local cache; evicted files are recomposed from remote chunks straight to the
    destination — the local cache is never populated. *)

type data_source = Local_cache | Remote_chunks | Symlink
type status = Exported of data_source | Missing_data
type summary = { exported : int; missing : int }

module Make (C : Conf.S) : sig
  (** Export the domain to [dst] (created if needed), calling [on_file] per file
      in sorted order. Files are the union of the backend listing and the local
      sidecar tree, so pending local-only files are included. *)
  val run :
    dst:string ->
    on_file:(rel:string -> status -> unit) ->
    unit ->
    summary Lwt.t
end
