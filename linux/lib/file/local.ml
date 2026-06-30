let tsync_root () =
  let xdg =
    match Sys.getenv_opt "XDG_CACHE_HOME" with
      | Some d -> d
      | None -> Filename.concat (Sys.getenv "HOME") ".cache"
  in
  Filename.concat xdg "tsync"

let cache_root domain_name = Filename.concat (tsync_root ()) domain_name

let manifest_root domain_name =
  Filename.concat (tsync_root ()) (".manifest/" ^ domain_name)

let strip_prefix ~domain_prefix key =
  let pfx = String.length domain_prefix in
  if String.length key > pfx && String.sub key 0 pfx = domain_prefix then
    String.sub key pfx (String.length key - pfx)
  else key

let cache_path ~domain_name ~domain_prefix key =
  Filename.concat (cache_root domain_name) (strip_prefix ~domain_prefix key)

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let ensure_parent_dir path = mkdir_p (Filename.dirname path)

let manifest_path ~domain_name ~domain_prefix key =
  Filename.concat (manifest_root domain_name) (strip_prefix ~domain_prefix key)

let create_dir ~domain_name ~domain_prefix key =
  mkdir_p (manifest_path ~domain_name ~domain_prefix key)

let delete_dir ~domain_name ~domain_prefix key =
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Array.iter
          (fun name -> rm_rf (Filename.concat path name))
          (Sys.readdir path);
        try Unix.rmdir path with Unix.Unix_error _ -> ()
      end
      else (try Unix.unlink path with Unix.Unix_error _ -> ())
  in
  rm_rf (manifest_path ~domain_name ~domain_prefix key)

let list_dir ~domain_name ~domain_prefix key =
  let path = manifest_path ~domain_name ~domain_prefix key in
  if Sys.file_exists path && Sys.is_directory path then
    Array.to_list (Sys.readdir path)
  else []

let is_cached ~domain_name ~domain_prefix key =
  Sys.file_exists (cache_path ~domain_name ~domain_prefix key)

let read_manifest ~domain_name ~domain_prefix key =
  let path = manifest_path ~domain_name ~domain_prefix key in
  if Sys.file_exists path then (
    try
      let ic = open_in path in
      let n = in_channel_length ic in
      let s = Bytes.create n in
      really_input ic s 0 n;
      close_in ic;
      Some (Bytes.to_string s)
    with _ -> None)
  else None

let delete_manifest ~domain_name ~domain_prefix key =
  let path = manifest_path ~domain_name ~domain_prefix key in
  try Unix.unlink path with Unix.Unix_error _ -> ()

let rename_manifest ~domain_name ~domain_prefix ~src_key ~dst_key =
  let src = manifest_path ~domain_name ~domain_prefix src_key in
  if Sys.file_exists src then begin
    let dst = manifest_path ~domain_name ~domain_prefix dst_key in
    ensure_parent_dir dst;
    Unix.rename src dst
  end

let rec clean_tmp_manifests dir =
  if Sys.file_exists dir && Sys.is_directory dir then
    Array.iter
      (fun name ->
        let path = Filename.concat dir name in
        if Sys.is_directory path then clean_tmp_manifests path
        else if Filename.check_suffix name ".tmp" then (
          try Unix.unlink path with Unix.Unix_error _ -> ()))
      (Sys.readdir dir)

let init ~domain_name =
  let root = manifest_root domain_name in
  mkdir_p root;
  clean_tmp_manifests root

let evict ~domain_name ~domain_prefix key =
  let path = cache_path ~domain_name ~domain_prefix key in
  try Unix.unlink path with Unix.Unix_error _ -> ()
