(** The background thread that notices what other clients did. *)

module Make (C : Conf.S) (F : File_ops.S) : sig
  (** One pass of {!Replay.apply_foreign}, for tests that want it on demand
      rather than on the timer. *)
  val sync_once : unit -> unit Lwt.t

  (** Start the poller. Checks the cursor every ~2 s and applies whatever
      {!Replay.apply_foreign} finds.

      [on_changed key] is called for each key a foreign op touched, after the op
      is applied. Defaults to a no-op; pass [Ipc.notify_changed ~path] to signal
      the FileProvider extension. *)
  val start : ?on_changed:(string -> unit) -> unit -> unit
end
