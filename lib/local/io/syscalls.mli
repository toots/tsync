(* A signal arriving mid-syscall makes it fail with EINTR rather than doing
   anything wrong, so every wrapper below just calls again; the daemon takes
   SIGCHLD and SIGWINCH often enough for this to matter.

   The rule is here and the calls are the platform's, which is what {!S} is
   for: it lists what a platform owes, in the names and argument order the
   caller already knows. *)

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

module Make (Io : Io.S) (Sys : S with type 'a io := 'a Io.t) : sig
  include S with type 'a io := 'a Io.t and type fd = Sys.fd

  (** Call [f] again for as long as it fails with [EINTR]. *)
  val retry_eintr : (unit -> 'a Io.t) -> 'a Io.t
end
