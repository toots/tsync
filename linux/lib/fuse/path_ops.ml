type t = {
  mknod : string -> int -> unit;
  fopen : string -> Fuse.file_info -> Fuse.file_info_update;
  read : string -> Fuse.buffer -> int64 -> Fuse.file_info -> int;
  write : string -> Fuse.buffer -> int64 -> Fuse.file_info -> int;
  release : string -> Fuse.file_info -> unit;
  unlink : string -> unit;
  rename : string -> string -> Fuse.rename_flags -> unit;
  truncate : string -> int64 -> Fuse.file_info option -> unit;
}
