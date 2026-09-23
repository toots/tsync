(* What the governor says goes to the daemon's log, sizes spelled as every
   report spells them. *)
module Reporter = struct
  let info s = Log.info "%s" s
  let warn s = Log.warn "%s" s
  let rate r = Metrics.human_bytes (int_of_float r) ^ "/s"
end

include Uplink.Make (Io_lwt.Core) (Io_lwt.Clock) (Reporter)

(* The daemon, once it serves the sync socket. *)
let own_links () = own (process ())

(* A body waiting for the link when the process stops is owed on disk, and
   no reason to hold the stop. *)
let (_unregister : unit -> unit) =
  Shutdown.on_request (fun () -> cancel_waiting (process ()) Shutdown.Stopping)

(* Everyone else, asking that socket. A renewal is one line and a second is
   plenty for it; one that takes longer is one unanswered. *)
let lease_from ~socket_path =
  lease_through (process ()) ~send:(fun line ->
      Ipc_lwt.send_lwt ~timeout:1. ~socket_path line)
