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

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let ensure_parent_dir path = mkdir_p (Filename.dirname path)

let is_cached ~domain_name ~domain_prefix key =
  let path = cache_path ~domain_name ~domain_prefix key in
  Sys.file_exists path

let manifest_path ~domain_name ~domain_prefix key =
  cache_path ~domain_name ~domain_prefix key ^ ".manifest"

let write_manifest ~domain_name ~domain_prefix key content =
  let path = manifest_path ~domain_name ~domain_prefix key in
  ensure_parent_dir path;
  let oc = open_out path in
  output_string oc content;
  close_out oc

let read_manifest ~domain_name ~domain_prefix key =
  let path = manifest_path ~domain_name ~domain_prefix key in
  if Sys.file_exists path then
    (try
       let ic = open_in path in
       let n = in_channel_length ic in
       let s = Bytes.create n in
       really_input ic s 0 n;
       close_in ic;
       Some (Bytes.to_string s, (Unix.stat path).Unix.st_mtime)
     with _ -> None)
  else None

let delete_manifest ~domain_name ~domain_prefix key =
  let path = manifest_path ~domain_name ~domain_prefix key in
  (try Unix.unlink path with Unix.Unix_error _ -> ())

let evict ~domain_name ~domain_prefix key =
  let path = cache_path ~domain_name ~domain_prefix key in
  (try Unix.unlink path with Unix.Unix_error _ -> ())
  (* manifest sidecar is kept intentionally *)
