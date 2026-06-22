let cache_root domain_name =
  let xdg =
    match Sys.getenv_opt "XDG_CACHE_HOME" with
      | Some d -> d
      | None -> Filename.concat (Sys.getenv "HOME") ".cache"
  in
  Filename.concat xdg ("tsync/" ^ domain_name)

(* Map an S3 key to a local cache path, stripping domain_prefix. *)
let cache_path ~domain_name ~domain_prefix key =
  let relative =
    if
      String.length key > String.length domain_prefix
      && String.sub key 0 (String.length domain_prefix) = domain_prefix
    then
      String.sub key
        (String.length domain_prefix)
        (String.length key - String.length domain_prefix)
    else key
  in
  Filename.concat (cache_root domain_name) relative

let is_cached ~domain_name ~domain_prefix key =
  let path = cache_path ~domain_name ~domain_prefix key in
  Sys.file_exists path

let evict ~domain_name ~domain_prefix key =
  let path = cache_path ~domain_name ~domain_prefix key in
  try Unix.unlink path with Unix.Unix_error _ -> ()

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let ensure_parent_dir path = mkdir_p (Filename.dirname path)
