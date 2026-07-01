type paths = {
  cache_root : string;
  socket_path : string;
  data_dir : string;
  config_path : string;
}

let implemented = false
let default_paths () = failwith "no runtime available"
let pre_start ~mount_point:_ = ()

module Make (C : Conf.S) = struct
  let mount _ = failwith "no runtime available"
end
