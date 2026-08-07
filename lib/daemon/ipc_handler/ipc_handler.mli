(** The daemon's command handler: one request in, one reply out.

    Everything needed to answer a request that cannot be derived from the domain
    — how a frontend's paths map to keys, how it evicts, how it reports itself —
    arrives as {!Make.hooks}, so the handler serves fuse, the FileProvider and
    the http proxy without knowing which it is talking for. *)

module Make (C : Conf.S) (F : File_ops.S) : sig
  type hooks = {
    path_to_key : string -> string;
    evict : string -> unit Lwt.t;
    restore : string -> unit Lwt.t;
    changed : string -> unit;
    full_resync : unit -> unit Lwt.t;
    status_fields : unit -> (string * Yojson.Safe.t) list;
    stats_fields : unit -> (string * Yojson.Safe.t) list;
    on_stop : unit -> unit;
  }

  (** Answer one request. [`Subscribe] hands the connection over to the event
      stream instead of replying further; [`Stop] asks the caller to shut down.
  *)
  val handler :
    hooks ->
    string ->
    (string * [ `Continue | `Stop | `Subscribe of string ]) Lwt.t
end
