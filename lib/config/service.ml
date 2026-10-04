let label = "org.feverdreamtv.tsync.daemon"
let app_bundle_id = "org.feverdreamtv.tsync"

let run args =
  match
    Unix.create_process (List.hd args) (Array.of_list args) Unix.stdin
      Unix.stdout Unix.stderr
  with
    | pid ->
        (* Reaped on every path: an interrupted wait is resumed. *)
        let rec reap () =
          match snd (Unix.waitpid [] pid) with
            | WEXITED n -> n
            | _ -> 1
            | exception Unix.Unix_error (EINTR, _, _) -> reap ()
        in
        reap ()
    | exception Unix.Unix_error _ -> 127

let target () = Printf.sprintf "gui/%d/%s" (Unix.getuid ()) label

let agent_definition () =
  Filename.concat (Paths.home ()) ("Library/LaunchAgents/" ^ label ^ ".plist")

let launch_app () = run ["/usr/bin/open"; "-g"; "-b"; app_bundle_id] = 0

let remove_agent () =
  ignore (run ["/bin/launchctl"; "bootout"; target ()]);
  try Unix.unlink (agent_definition ()) with Unix.Unix_error _ -> ()
