(* [send_lwt] carries a timeout this has no use for, and a name that says which
   scheduler it is. *)
module Send = struct
  let send ~socket_path line = Ipc.send_lwt ~socket_path line
end

include Job_report.Make (Io_lwt.Core) (Io_lwt.Clock) (Io_lwt.Bounded) (Send)
