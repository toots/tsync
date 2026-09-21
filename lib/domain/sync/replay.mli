(** Everything that reads a journal: our own unfinished work, and other
    clients'.

    It lives here rather than in the CLI because both callers need it, and
    because a copy living in an executable was unreachable from [tests/] — which
    is how one domain sat on 295 stale records for hours. *)

module type JOURNAL = Replay_intf.JOURNAL
module type S = Replay_intf.S

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = Replay_intf.OVER

module Over
    (Io : Io.S)
    (_ : Bounded.S with type 'a io := 'a Io.t)
    (_ : JOURNAL with type 'a io := 'a Io.t)
    (_ : Wal.OVER with type 'a io := 'a Io.t)
    (_ : Staged_manifest.OVER with type 'a io := 'a Io.t) : sig
  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File_ops.S with type 'a io := 'a Io.t) : S with type 'a io := 'a Io.t
end
