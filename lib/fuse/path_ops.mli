type t = {
  mknod : string -> int -> unit Lwt.t;
  fopen : string -> Fuse.file_info -> Fuse.file_info_update Lwt.t;
  read : string -> Fuse.buffer -> int64 -> Fuse.file_info -> int Lwt.t;
  write : string -> Fuse.buffer -> int64 -> Fuse.file_info -> int Lwt.t;
  release : string -> Fuse.file_info -> unit Lwt.t;
  unlink : string -> unit Lwt.t;
  rename : string -> string -> Fuse.rename_flags -> unit Lwt.t;
  truncate : string -> int64 -> Fuse.file_info option -> unit Lwt.t;
}
