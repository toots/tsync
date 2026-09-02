include Ipc

(* What {!Ipc.Make} needs of a transport, over this process's sockets. A line is
   the unit on the wire, so [read_line] raising at end of input is how a client
   going away reaches the loops above. *)
module Transport = struct
  type input = Lwt_io.input_channel
  type output = Lwt_io.output_channel
  type server = Lwt_io.server

  let connect path = Lwt_io.open_connection (Unix.ADDR_UNIX path)
  let read_line = Lwt_io.read_line
  let write_line = Lwt_io.write_line
  let flush = Lwt_io.flush
  let close = Lwt_io.close

  let serve ~path handler =
    Lwt_io.establish_server_with_client_address (Unix.ADDR_UNIX path)
      (fun _addr channels -> handler channels)

  let shutdown = Lwt_io.shutdown_server
end

module Loop = Ipc.Make (Io_lwt.Core) (Io_lwt.Lock) (Io_lwt.Clock) (Transport)

(* Named apart from {!Ipc.send} rather than shadowing it: the two differ in
   whether they block the loop, which is the whole reason both exist. *)
let send_lwt = Loop.send
let serve = Loop.serve

module Subs = Loop.Subs
