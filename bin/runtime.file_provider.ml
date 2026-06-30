let implemented = true
let auto_evict = File_provider.auto_evict
let set_pending_version = File_provider.set_pending_version

let default_paths () =
  let app_group =
    Filename.concat (Sys.getenv "HOME")
      "Library/Group Containers/group.com.toots.tsync"
  in
  ( Filename.concat app_group "tsync",
    Filename.concat app_group "tsync/tsync.sock" )

let pre_start ~mount_point:_ = ()
type context = File_provider.context
let make_context = File_provider.make_context
let mount = File_provider.mount
