module Make (C : Conf.S) (F : File_ops.S) : sig
  (** One pass of {!Replay.apply_foreign}, for tests that want it on demand
      rather than on the timer. *)
  val sync_once : unit -> unit Lwt.t

  (** Start the background sync poller thread. Polls the cursor every ~2 s and
      applies whatever {!Replay.apply_foreign} finds.

      [on_changed key] is called for each key touched by a foreign op (after
      applying the op). Defaults to a no-op; pass [Ipc.notify_changed ~path] to
      signal the FileProvider extension. *)
  val start : ?on_changed:(string -> unit) -> unit -> unit
end
