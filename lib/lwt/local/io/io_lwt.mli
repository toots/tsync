(** The only module that names a scheduler. Everything above it takes what it
    needs as a parameter, so what runs the work is decided once, here. *)

module Core : Io.S with type 'a t = 'a Lwt.t and type 'a u = 'a Lwt.u

module Unix_syscalls :
  Syscalls.S with type 'a io := 'a Lwt.t and type fd = Lwt_unix.file_descr

module Fs_primitives :
  Fs.PRIMITIVES with type 'a io := 'a Lwt.t and type fd := Lwt_unix.file_descr

module Clock : Clock.S with type 'a io := 'a Lwt.t

module Lock :
  Lock.S
    with type 'a io := 'a Lwt.t
     and type mutex = Lwt_mutex.t
     and type condition = unit Lwt_condition.t

module Bounded : module type of Tsync_io.Bounded.Make (Core)
module Syscalls : module type of Tsync_io.Syscalls.Make (Core) (Unix_syscalls)

module Fs : sig
  include module type of Tsync_io.Fs.Make (Core) (Unix_syscalls) (Fs_primitives)

  (** {!mkdir_p} for callers running before there is a loop to run in: process
      startup, the CLI, the config writer. *)
  val mkdir_p_sync : ?perm:int -> string -> unit

  (** A read-only descriptor on [path], unlinked before this returns: the caller
      gets the bytes without the name, and nothing is left behind if it dies
      holding them. *)
  val open_and_unlink : string -> Unix.file_descr

  (** Whether [pid] names a running process. A pid reused since it was recorded
      reads as alive. *)
  val pid_alive : int -> bool

  (** Capacity of a filesystem, in bytes. [avail] is what an unprivileged writer
      can still use; [free] also counts the margin reserved for root, and is the
      one a used-space figure must be derived from. *)
  type disk_space = Tsync_io.Fs.disk_space = {
    avail : int64;
    free : int64;
    total : int64;
  }

  (** [disk_space path] is the capacity of the filesystem holding [path], or
      [None] when [path] cannot be stat'd. One syscall: cheap enough to call per
      status request. *)
  val disk_space : string -> disk_space option

  (** The machine's one-minute load average, where the platform reports one. *)
  val load_average : unit -> float option
end
