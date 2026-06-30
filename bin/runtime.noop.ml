let implemented = false
let pre_start ~mount_point:_ = ()
let auto_evict = ref false
let set_pending_version _ = ()
type context = unit
let make_context ~store:_ ~files:_ ~domain_name:_ ~domain_prefix:_ ~mount_point:_ = ()
let mount () _ = ()
