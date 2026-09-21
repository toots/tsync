(** The daemon's command handler: one request in, one reply out.

    Everything needed to answer a request that cannot be derived from the domain
    — how a frontend's paths map to keys, how it evicts, how it reports itself —
    arrives as {!Make.hooks}, so the handler serves fuse, the FileProvider and
    the http proxy without knowing which it is talking for. *)

(** A failure, in the shape every reply on this wire uses. Frontends that answer
    IPC without going through {!Make} — the http proxy serves its own socket —
    encode through this rather than spelling the fields again, so a client can
    match on the code instead of the wording. *)
val error_reply : Ipc_error.t -> string -> string

(** Whether a request line names an action that changes the domain, and so may
    leave an upload owed once answered. *)
val mutates : string -> bool

(** Named so a domain's wiring can be handed to a frontend as one signature. *)
module type S = Ipc_handler_intf.S

module Make
    (_ : Conf_lwt.S)
    (_ : File_ops.S with type 'a io := 'a Lwt.t)
    (_ : Sync_queue.S with type 'a io := 'a Lwt.t)
    (_ : Pause.S) : S
