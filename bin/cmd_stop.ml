open Cmdliner
open Cli

let cmd : unit Cmd.t =
  let run () =
    (* The same sockets a report is gathered from, so a frontend that can be
       asked about can be asked to stop. An absent or unconnectable one just
       means that part is not running. *)
    let sockets = List.sort_uniq compare (List.map snd (domain_targets ())) in
    let stopped = ref 0 in
    List.iter
      (fun socket_path ->
        match Ipc.action ~socket_path "stop" with
          | _ -> incr stopped
          | exception Unix.Unix_error ((Unix.ECONNREFUSED | Unix.ENOENT), _, _)
            ->
              ()
          | exception Failure msg ->
              Printf.eprintf "Error stopping %s: %s\n" socket_path msg)
      sockets;
    if !stopped > 0 then Printf.printf "Stopped %d domain(s).\n" !stopped
    else print_endline "No IPC-backed frontend running; relying on signal."
  in
  Cmd.v
    (Cmd.info "stop" ~doc:"Stop the sync daemon")
    Term.(const run $ const ())
