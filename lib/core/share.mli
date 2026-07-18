(** [zip_entry_name ~domain_prefix ~rel key] is the zip entry name for object
    [key] when sharing the folder [rel], rooted at the shared folder itself
    ("A/B/shared/f" -> "shared/f"). [rel] has no trailing slash; "" shares the
    whole domain (entries stay domain-relative). *)
val zip_entry_name : domain_prefix:string -> rel:string -> string -> string
