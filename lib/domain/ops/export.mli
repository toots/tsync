(** Export every file of a domain to a plain folder, reading manifests directly
    (no daemon needed). Content is assembled through the ordinary read path, so
    unsynced local edits, partially cached files and never-cached ones all
    export alike; the chunks that are missing are fetched on the way. *)

type status = Exported | Exported_symlink | Missing_data
type summary = { exported : int; missing : int }

(** Walking the backend's folder tree, which is how a whole domain is reached
    from its root. *)
module type TREE = sig
  type 'a io
  type pool

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val fold_tree :
      ?on_unusable:Inode_tree.on_unusable ->
      ?refresh_index:bool ->
      ?on_index:(Stored_key.t -> unit) ->
      ?slots:pool ->
      folder_id:string ->
      key:Logical_key.t ->
      ('a -> Logical_key.t -> Inode_tree.entry -> 'a io) ->
      'a ->
      'a io
  end
end

(** What is already in the checkout, and what the staged half is holding. *)
module type CHECKOUT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val walk : unit -> string list io
  end
end

module type STAGED = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val exists : Logical_key.t -> bool io
  end
end

(** Putting a file's bytes somewhere, which is the export itself. Its own store
    is wired in where the modules are built, since nothing here names one. *)
module type CONTENT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val published : Logical_key.t -> Manifest.t option io
    val assemble_to : Logical_key.t -> dst_path:string -> unit io
  end
end

module Over
    (Io : Io.S)
    (_ : Fs.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : TREE with type 'a io := 'a Io.t)
    (_ : CHECKOUT with type 'a io := 'a Io.t)
    (_ : STAGED with type 'a io := 'a Io.t)
    (_ : CONTENT with type 'a io := 'a Io.t) : sig
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
