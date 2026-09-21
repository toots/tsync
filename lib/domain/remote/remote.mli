exception Cancelled

(** The file an upload was reading changed under it, so nothing is published:
    its chunks would otherwise describe bytes the file never held together. The
    caller re-imports to pick up what it now holds. *)
exception Source_changed of string

(** Cap on the per-session memo of chunk keys known present. Reaching it clears
    the memo, which costs a HEAD per chunk again. Settable so a test can reach
    it without uploading a terabyte. *)
val set_max_known : int -> unit

module type S = Remote_intf.S

(** {!S} for whichever domain it is applied to: what a consumer takes. *)
module type OVER = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (_ : Bounded.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : Layout.OVER with type 'a io := 'a Io.t)
    (_ : Store.OVER with type 'a io := 'a Io.t)
    (_ : History.OVER with type 'a io := 'a Io.t)
    (_ : Collection.OVER with type 'a io := 'a Io.t)
    (_ : Corruption.OVER with type 'a io := 'a Io.t) : sig
  (** Keys are mapped to backend keys through [L]. Callers holding real paths
      want {!Make}; {!Layout.Identity} serves callers that already hold backend
      keys. *)
  module Make_with_layout
      (_ : Conf.S with type 'a io = 'a Io.t)
      (_ : Layout.S with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t

  module Make (_ : Conf.S with type 'a io = 'a Io.t) :
    S with type 'a io := 'a Io.t
end
