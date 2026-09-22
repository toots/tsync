include Uplink.Make (Io_lwt.Core) (Io_lwt.Clock)

(* The daemon, once it serves the sync socket. *)
let own_link () = own (process ())

(* Everyone else, asking that socket. A renewal is one line and a second is
   plenty for it; one that takes longer is one unanswered. *)
let lease_from ~socket_path =
  lease_through (process ()) ~send:(fun line ->
      Ipc_lwt.send_lwt ~timeout:1. ~socket_path line)
