let implemented = true

let default_paths () =
  let cache_base =
    match Sys.getenv_opt "XDG_CACHE_HOME" with
      | Some d -> d
      | None -> Filename.concat (Sys.getenv "HOME") ".cache"
  in
  let data_base =
    match Sys.getenv_opt "XDG_DATA_HOME" with
      | Some d -> d
      | None -> Filename.concat (Sys.getenv "HOME") ".local/share"
  in
  ( Filename.concat cache_base "tsync",
    Filename.concat data_base "tsync/tsync.sock" )

let pre_start ~mount_point =
  ignore
    (Sys.command
       (Printf.sprintf "fusermount3 -u %s 2>/dev/null"
          (Filename.quote mount_point)))
let auto_evict = Fuse_fs.auto_evict
let set_pending_version = Fuse_fs.set_pending_version
type context = Fuse_fs.context
let make_context ~store ~files ~domain_name ~domain_prefix ~mount_point =
  Context.{ store; files; domain_name; domain_prefix; mount_point }
let mount = Fuse_fs.mount
