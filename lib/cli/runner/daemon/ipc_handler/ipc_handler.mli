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

(** Named so a domain's wiring can be handed to a frontend as one signature. *)
module type S = sig
  type hooks = {
    evict : Logical_key.t -> unit Lwt.t;
    restore : Logical_key.t -> unit Lwt.t;
    changed : Logical_key.t -> unit;
    full_resync : unit -> unit Lwt.t;
    status_fields : unit -> (string * Yojson.Safe.t) list;
    stats_fields : unit -> (string * Yojson.Safe.t) list;
    on_stop : unit -> unit;
  }

  (** The item [s] names, [None] for a reference this client cannot resolve or
      does not recognise. For a frontend command answering from the mirror
      rather than through a request. *)
  val key_of_ref : string -> Logical_key.t option Lwt.t

  (** The reference naming what [key] names, for a caller that holds a key and
      must say so to the daemon. The kind is read from the mirror, a key not
      carrying one. [None] for a key whose folder this client cannot resolve. *)
  val item_ref : Logical_key.t -> string option Lwt.t

  (** Answer one request. [`Subscribe] hands the connection over to the event
      stream instead of replying further; [`Stop] asks the caller to shut down.
  *)
  val handler :
    hooks ->
    string ->
    (string * [ `Continue | `Stop | `Subscribe of string ]) Lwt.t
end

module Make (_ : Conf.S) (_ : File_ops.S) : S
