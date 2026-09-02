(** A backend over a directory on this machine.

    Exposes only the functor: the store a caller gets is registered under
    ["local"] by the instance that applies this, and asked for by name through
    {!Backend.Make.make}. The library still has to be linked — [-linkall] is
    what puts the registration in the binary. *)

(** Being told a directory changed. [None] from [open_dir] is a directory this
    platform or filesystem will not watch, which is not a failure: the caller
    goes back to asking on a timer. *)
module type WATCHER = sig
  type 'a io
  type t

  val open_dir : string -> t option
  val wait : t -> unit io
end

(** Writing a buffer straight to a path, which the bigstring layer owns. *)
module type BYTES = sig
  type 'a io

  val write_to : path:string -> Bigstring.t -> offset:int -> unit io
end

module Over
    (Io : Io.S)
    (_ : Fs.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : Bounded.S with type 'a io := 'a Io.t)
    (_ : BYTES with type 'a io := 'a Io.t)
    (_ : Clock.S with type 'a io := 'a Io.t)
    (_ : WATCHER with type 'a io := 'a Io.t) : sig
  module type Store = Backend.S with type 'a io := 'a Io.t

  (** The fields a configured store is described by, for the registry. *)
  val spec : Field_spec.t list

  (** [verify_writes] holds each chunk against its own name as it is written:
      one read back per chunk, usually from page cache. *)
  val make : ?verify_writes:bool -> root:string -> unit -> (module Store)
end
