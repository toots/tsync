module Make (C : Conf.S) (F : File.S) : sig
  type hooks = {
    path_to_key : string -> string;
    request_evict : string -> unit Lwt.t;
    restore : string -> unit Lwt.t;
    changed : string -> unit;
    full_resync : unit -> unit Lwt.t;
    status_fields : unit -> (string * Yojson.Safe.t) list;
    stats_fields : unit -> (string * Yojson.Safe.t) list;
    on_stop : unit -> unit;
  }

  val handler : hooks -> string -> (string * [ `Continue | `Stop ]) Lwt.t
end
