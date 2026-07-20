(** Versioning stores a timestamped copy of a file's manifest under
    [versions_prefix] every time the file is modified, renamed or deleted (see
    {!Store.save_version}). Since manifests reference shared content-addressed
    chunks, a version is a cheap manifest copy and can be restored without
    transferring any file content. Chunks are collected only when [Expire]
    removes the last version referencing them. *)

(** Split a version object key into its identity (a [folder-id/leaf-hash] pair,
    used only as an opaque grouping key) and its timestamp suffix, or [None] if
    it is not under [versions_prefix]. *)
val parse : versions_prefix:string -> string -> (string * string) option
