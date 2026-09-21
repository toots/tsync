module type S = sig
  type hooks = {
    evict : Logical_key.t -> unit Lwt.t;
    restore : ?keep:float -> Logical_key.t -> unit Lwt.t;
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
