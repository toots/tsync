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
  include module type of struct
    include Tsync_io.Fs
  end

  include module type of Tsync_io.Fs.Make (Core) (Unix_syscalls) (Fs_primitives)
end
