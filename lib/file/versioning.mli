(** Build the trash key for a file being soft-deleted under versioning.
    Strips [domain_prefix] from [key], then places the result under
    [trash_prefix] with a Unix timestamp suffix. *)
val trash_key :
  s3_key:string -> domain_prefix:string -> trash_prefix:string -> string
