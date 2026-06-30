type t = {
  store : File_store.t;
  files : File.store;
  domain_name : string;
  domain_prefix : string;
  mount_point : string;
}

val fuse_to_key : t -> string -> string
val fuse_to_dir_prefix : t -> string -> string
