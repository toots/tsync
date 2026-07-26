(** Export every file of a domain to a plain folder, reading manifests directly
    (no daemon needed). Content is assembled through the ordinary read path, so
    unsynced local edits, partially cached files and never-cached ones all
    export alike; the chunks that are missing are fetched on the way. *)

type status = Exported | Exported_symlink | Missing_data
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
