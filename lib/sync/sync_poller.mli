(** The background thread that notices what other clients did. *)

module Make (C : Conf.S) (F : File_ops.S with type 'a io := 'a Lwt.t) : sig
  (** One pass: read the cursor, and if it has moved since the last pass apply
      whatever {!Replay.apply_foreign} finds, answering how many entries that
      was. The cursor is the gate — a peer bumps it after publishing — so an
      entry it does not point past is one this never goes looking for.

      [on_changed key] is called for each key a foreign op touched, after the op
      is applied. *)
  val sync_once : on_changed:(string -> unit) -> unit -> int Lwt.t

  (** {!sync_once} on a ~2 s timer, detached. *)
  val start : on_changed:(string -> unit) -> unit -> unit
end
