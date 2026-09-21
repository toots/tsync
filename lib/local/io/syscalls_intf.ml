module type S = sig
  type 'a io
  type fd

  val file_exists : string -> bool io
  val stat : string -> Unix.stats io
  val lstat : string -> Unix.stats io
  val readlink : string -> string io
  val symlink : ?to_dir:bool -> string -> string -> unit io
  val rename : string -> string -> unit io
  val unlink : string -> unit io
  val link : string -> string -> unit io
  val mkdir : string -> Unix.file_perm -> unit io
  val rmdir : string -> unit io
  val openfile : string -> Unix.open_flag list -> Unix.file_perm -> fd io
  val close : fd -> unit io
  val read : fd -> Bytes.t -> int -> int -> int io
  val write : fd -> Bytes.t -> int -> int -> int io
  val pread : fd -> Bytes.t -> file_offset:int -> int -> int -> int io
  val pwrite : fd -> Bytes.t -> file_offset:int -> int -> int -> int io
  val pwrite_string : fd -> string -> file_offset:int -> int -> int -> int io
  val utimes : string -> float -> float -> unit io
  val fsync : fd -> unit io

  module LargeFile : sig
    val stat : string -> Unix.LargeFile.stats io
    val lstat : string -> Unix.LargeFile.stats io
    val fstat : fd -> Unix.LargeFile.stats io
    val ftruncate : fd -> int64 -> unit io
    val lseek : fd -> int64 -> Unix.seek_command -> int64 io
  end
end
