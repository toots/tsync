(** A filesystem, as far as anything above it needs one.

    Most of what is here is not a syscall: a recursive mkdir, a temp-and-rename,
    a walk that removes a tree. {!Make} writes that once against {!Io.S} and the
    few operations a platform actually owes, which is {!PRIMITIVES}. *)

(** {!Make}'s [mkdir_p] for callers running before there is a loop to run in:
    process startup, the CLI, the config writer. *)
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
type disk_space = { avail : int64; free : int64; total : int64 }

(** [disk_space path] is the capacity of the filesystem holding [path], or
    [None] when [path] cannot be stat'd. One syscall: cheap enough to call per
    status request. *)
val disk_space : string -> disk_space option

(** The machine's one-minute load average, where the platform reports one: what
    else the box is carrying is the first thing a process figure is read
    against. *)
val load_average : unit -> float option

(** What a platform owes beyond {!Syscalls.S}: whole files, a directory's names,
    and bigstrings on a descriptor. Everything {!Make} adds is built from these.
*)
module type PRIMITIVES = Fs_intf.PRIMITIVES

module type S = Fs_intf.S

module Make
    (Io : Io.S)
    (Sys : Syscalls.S with type 'a io := 'a Io.t)
    (P : PRIMITIVES with type 'a io := 'a Io.t and type fd := Sys.fd) :
  S with type 'a io := 'a Io.t and type fd = Sys.fd
