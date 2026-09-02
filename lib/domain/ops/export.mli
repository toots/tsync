(** Export every file of a domain to a plain folder, reading manifests directly
    (no daemon needed). Content is assembled through the ordinary read path, so
    unsynced local edits, partially cached files and never-cached ones all
    export alike; the chunks that are missing are fetched on the way. *)

type status = Exported | Exported_symlink | Missing_data
type summary = { exported : int; missing : int }

module Over
    (Io : Io.S)
    (_ : Fs.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : Inode_tree.OVER with type 'a io := 'a Io.t)
    (_ : Checkout.OVER with type 'a io := 'a Io.t)
    (_ : Staged_manifest.OVER with type 'a io := 'a Io.t)
    (_ : Remote.OVER with type 'a io := 'a Io.t)
    (_ : Data.OVER with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** Export the domain to [dst] (created if needed), calling [on_file] per
        file in sorted order. Files are the union of the backend listing and the
        local sidecar tree, so pending local-only files are included.

        [on_plan] fires once the set to export is known and [on_start] as each
        file is picked up. A caller saying what the export is working on wants
        [on_start]: an evicted file is recomposed from remote chunks between the
        two, which for a large one is the whole of the time anybody asks about.
    *)
    val run :
      ?on_plan:(files:int -> unit) ->
      ?on_start:(rel:string -> unit) ->
      dst:string ->
      on_file:(rel:string -> status -> unit) ->
      unit ->
      summary Io.t
  end
end
