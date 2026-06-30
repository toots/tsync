let implemented = true

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
