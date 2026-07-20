(* Single source of truth for the local cache directory layout, per domain:
     <cache_root>/manifests/<domain>/…  — manifest mirror (+ .tsync-dir markers)
     <cache_root>/cached/<domain>/…     — downloaded file data
   The two trees mirror each other by real path. Both [Local] (manifest sidecars
   + cached data) and [Folder_ids] (folder markers) derive their paths from here,
   so the manifest mirror has exactly one definition. *)

let manifests_dir ~cache_root domain_name =
  Filename.concat cache_root (domain_name ^ "/manifests")

let cached_dir ~cache_root domain_name =
  Filename.concat cache_root (domain_name ^ "/cached")
