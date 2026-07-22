(** Caches one open file descriptor per key across a FUSE file's open-to-release
    lifetime, refcounted for concurrent opens of the same key. Without this,
    every FUSE read/write call would open, seek and close the underlying cache
    file on its own — fine for one call, but for a large file split into many
    kernel read/write requests it multiplies into thousands of redundant
    syscalls per file. This is FUSE-specific lifecycle management (tied to
    fopen/release), so it lives here rather than in the more general-purpose
    [File] module. *)
module Make (F : File.S) : sig
  (** Open (or, if already open, reuse) the fd for [key] and bump its refcount.
      Call once per FUSE fopen. *)
  val acquire : string -> unit Lwt.t

  (** Drop a reference to [key]'s fd, closing it once the last reference is
      released. Call once per FUSE release. *)
  val release : string -> unit Lwt.t

  (** The cached fd for [key], if [acquire] has been called for it and [release]
      hasn't yet dropped the last reference. *)
  val find : string -> Lwt_unix.file_descr option
end
