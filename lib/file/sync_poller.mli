module Make (C : Conf.S) (F : File.S) : sig
  (** Apply any foreign journal entries added since the last sync. Reads the
      journal, skips entries written by this client, and calls
      [F.apply_foreign_ops] on the rest. Useful for testing and for the
      [tsync sync] command; the polling loop calls this on every version bump.
  *)
  val sync_once : unit -> unit Lwt.t

  (** Start the background sync poller thread. Polls the version key every ~2 s
      and applies foreign journal entries via [F.apply_foreign_ops].

      [on_changed key] is called for each key touched by a foreign op (after
      applying the op). Defaults to a no-op; pass [Ipc.notify_changed ~path] to
      signal the FileProvider extension. *)
  val start : ?on_changed:(string -> unit) -> unit -> unit
end
