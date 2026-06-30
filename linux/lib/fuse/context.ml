type t = {
  store : File_store.t;
  files : File.store;
  domain_name : string;
  domain_prefix : string;
  mount_point : string;
}

let fuse_to_key ctx path =
  let rel =
    if path = "/" then "" else String.sub path 1 (String.length path - 1)
  in
  ctx.domain_prefix ^ rel

let fuse_to_dir_prefix ctx path =
  let key = fuse_to_key ctx path in
  if key = ctx.domain_prefix then key
  else if String.length key > 0 && key.[String.length key - 1] = '/' then key
  else key ^ "/"
