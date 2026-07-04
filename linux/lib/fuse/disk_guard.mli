(** Preserve a minimum fraction of free space on the filesystem holding the
    local cache, by gating downloads/writes and evicting clean cached files
    (least recently used first). The watermark is read from the preserve-space
    state file (see {!Ipc.preserve_space_percent}) on every tick. *)

module Make (_ : Conf.S) (_ : File.S) : sig
  (** Blocks while the guard is engaged; install as {!File.S.set_io_gate}. *)
  val wait : unit -> unit Lwt.t

  (** Never-returning check loop; run with [Lwt.async]. *)
  val monitor : unit -> unit Lwt.t

  (** Fields for the [stats] IPC response: [preserveSpacePercent] (null when
      disabled) and [throttled]. *)
  val status : unit -> (string * Yojson.Safe.t) list
end
