(** Versioning stores a timestamped copy of a file's manifest under
    [versions_prefix] every time the file is modified, renamed or deleted (see
    {!Store.save_version}). Manifests reference shared content-addressed chunks,
    so a version costs a manifest copy and restores without transferring any
    content, and a chunk is reclaimed only once no version names it. *)

(** Split a version object key into its identity (a [folder-id/leaf-hash] pair,
    used only as an opaque grouping key) and its timestamp suffix, or [None] if
    it is not under [versions_prefix]. *)
val parse : versions_prefix:string -> string -> (string * string) option
