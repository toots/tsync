(** The shared journal on the backend, and the local mark saying how far it has
    been read. The only module that turns an entry key into a backend key. *)

(** How long a cursor bump may wait to be collected with others. Settable so a
    test observing a flush need not sleep it out. *)
val set_cursor_flush_interval : float -> unit

module type S = File_store_intf.S

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = sig
  type 'a io

  module Make (C : Conf.S with type 'a io = 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (_ : Lock.S with type 'a io := 'a Io.t)
    (_ : Clock.S with type 'a io := 'a Io.t)
    (_ : Store.INODE with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t
