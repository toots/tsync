(** Everything that reads a journal: our own unfinished work, and other
    clients'.

    It lives here rather than in the CLI because both callers need it. The
    daemon runs for weeks and never reconciled its own intent log — which is why
    one domain sat on 295 stale records for hours — and nothing under [tests/]
    could reach a copy that lived in an executable. *)
module Make (C : Conf.S) (F : File_ops.S) : sig
  (** Finish or discard every record this client left behind, oldest first, each
      under the entry key it already has. Startup only: it replays ops and
      re-queues uploads, so it must not run while writes are staging.

      Also sweeps staged bodies nothing references, and adopts staged data no
      record names — a crash between staging and recording. *)
  val reconcile : unit -> unit Lwt.t

  (** Apply every journal entry from another client since the applied mark, in
      order, advancing the mark behind each one. A failure stops the pass and
      leaves the mark where it was, so the entry is retried rather than skipped.

      [on_changed] is called with each affected backend key, for a frontend that
      invalidates its own view. Returns how many foreign entries were applied.
  *)
  val apply_foreign : ?on_changed:(string -> unit) -> unit -> int Lwt.t
end
