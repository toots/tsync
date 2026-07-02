module Make (C : Conf.S) (F : File.S) : sig
  type hooks = {
    path_to_key : string -> string;
    request_evict : string -> unit;
    restore : string -> unit;
    changed : string -> unit;
    full_resync : unit -> unit;
    status_fields : unit -> (string * Yojson.Safe.t) list;
    on_stop : unit -> unit;
  }

  val handler : hooks -> string -> string * [ `Continue | `Stop ]
end
