(** The background thread that notices what other clients did. *)

(** What this needs below it. *)
module type JOURNAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val fetch_cursor : unit -> Journal.Entry_key.t option io
  end
end

module type CLOCK = sig
  type 'a io

  val sleep : float -> unit io
end

module Over
    (Io : Io.S)
    (_ : CLOCK with type 'a io := 'a Io.t)
    (_ : JOURNAL with type 'a io := 'a Io.t)
    (_ : sig
      module Make
          (_ : Conf.S with type 'a io = 'a Io.t)
          (_ : File_ops.S with type 'a io := 'a Io.t) : sig
        val apply_foreign : on_changed:(string -> unit) -> unit -> int Io.t
      end
    end) : sig
  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File_ops.S with type 'a io := 'a Io.t) : sig
    (** One pass: read the cursor, and if it has moved since the last pass apply
        whatever {!Replay.apply_foreign} finds, answering how many entries that
        was. The cursor is the gate — a peer bumps it after publishing — so an
        entry it does not point past is one this never goes looking for.

        [on_changed key] is called for each key a foreign op touched, after the
        op is applied. *)
    val sync_once : on_changed:(string -> unit) -> unit -> int Io.t

    (** {!sync_once} on a ~2 s timer, detached. *)
    val start : on_changed:(string -> unit) -> unit -> unit
  end
end
