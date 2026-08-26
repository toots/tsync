(** A backend over a directory on this machine.

    Exposes only the functor: the store a caller gets is registered under
    ["local"] by the instance that applies this, and asked for by name through
    {!Backend.Make.make}. The library still has to be linked — [-linkall] is
    what puts the registration in the binary. *)

(** What a store on a filesystem needs below it. *)
module type FS = sig
  type 'a io

  val mkdir_p : string -> unit io
  val ensure_parent : string -> unit io
  val readdir_list : string -> string list io
  val rm_rf : string -> unit io
  val unlink_quiet : string -> unit io
end

module type SYSCALLS = sig
  type 'a io

  val stat : string -> Unix.stats io
  val link : string -> string -> unit io
  val rename : string -> string -> unit io
  val unlink : string -> unit io
  val rmdir : string -> unit io

  module LargeFile : sig
    val stat : string -> Unix.LargeFile.stats io
  end
end

module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val use : t -> (unit -> 'a io) -> 'a io
  val each : width:int -> (unit -> (unit -> unit io) option) -> unit io
end

module type CLOCK = sig
  val now : unit -> float
end

(** Writing a buffer straight to a path, which the bigstring layer owns. *)
module type BYTES = sig
  type 'a io

  val write_to : path:string -> Bigstring.t -> offset:int -> unit io
end

module Over
    (Io : Io.S)
    (_ : FS with type 'a io := 'a Io.t)
    (_ : SYSCALLS with type 'a io := 'a Io.t)
    (_ : POOLS with type 'a io := 'a Io.t)
    (_ : BYTES with type 'a io := 'a Io.t)
    (_ : CLOCK) : sig
  module type Store = Backend.S with type 'a io := 'a Io.t

  (** The fields a configured store is described by, for the registry. *)
  val spec : Field_spec.t list

  (** [verify_writes] holds each chunk against its own name as it is written:
      one read back per chunk, usually from page cache. *)
  val make : ?verify_writes:bool -> root:string -> unit -> (module Store)
end
