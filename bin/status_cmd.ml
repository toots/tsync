open Cmdliner
open Tsync_core
open Tsync_ipc
open Tsync_config
open Cli

let processes report =
  let open Yojson.Safe.Util in
  match report |> member "processes" with
    | `List (_ :: _ as processes) ->
        say "Processes";
        List.iter
          (fun p ->
            let role =
              p |> member "role" |> to_string_option
              |> Option.value ~default:"?"
            in
            let pid =
              match p |> member "pid" with
                | `Int n -> string_of_int n
                | _ -> "-"
            in
            let serves =
              match p |> member "serves" with
                | `List l ->
                    String.concat ", " (List.filter_map to_string_option l)
                | _ -> ""
            in
            let bytes k =
              match p |> member "process" |> member k with
                | `Int n ->
                    Printf.sprintf "%.0f MiB" (float_of_int n /. 1048576.)
                | _ -> "?"
            in
            say "  %-12s %7s  %s" role pid serves;
            if p |> member "process" <> `Null then
              say "    private %s (heap %s, anonymous %s), mapped files %s"
                (bytes "privateBytes") (bytes "heapBytes")
                (bytes "anonymousBytes") (bytes "fileBackedBytes"))
          processes
    | _ -> ()

(* 07 §5.5 *)
let status json verbose =
  set_verbose verbose;
  run (fun () ->
      let report =
        match
          Ipc.call
            (Paths.supervisor_socket ())
            (`Assoc [("action", `String "stats")])
        with
          | r -> r
          | exception Ipc.Not_serving _ ->
              let config = config () in
              let domains =
                Rt.map_concurrently
                  (fun (d : Config.domain) ->
                    let name = Domain_name.to_string d.name in
                    match
                      Ipc.call
                        (Paths.owner_socket d.name)
                        (`Assoc
                           [
                             ("action", `String "stats");
                             ("domain", `String name);
                             ("arg", `String "frontend");
                           ])
                    with
                      | `Assoc l -> (
                          match List.assoc_opt "domains" l with
                            | Some (`List ds) -> ds
                            | _ -> [])
                      | _ | (exception _) ->
                          [
                            `Assoc
                              [
                                ("name", `String name);
                                ("unanswered", `Bool true);
                              ];
                          ])
                  config.domains
              in
              Ipc.ok
                [
                  ("host", `String (Unix.gethostname ()));
                  ("domains", `List (List.concat domains));
                ]
      in
      (if json then
         print_endline
           (Yojson.Safe.pretty_to_string
              (match report with
                | `Assoc l -> `Assoc (("t", `Float (Unix.gettimeofday ())) :: l)
                | j -> j))
       else
         let open Yojson.Safe.Util in
         say "tsync on %s" (report |> member "host" |> to_string);
         List.iter
           (fun d ->
             let name = d |> member "name" |> to_string in
             if d |> member "unanswered" = `Bool true then
               say "  %s: NOT ANSWERING" name
             else (
               let paused = d |> member "paused" = `Bool true in
               let sync = d |> member "sync" in
               let queues = d |> member "queues" in
               say "  %s%s" name (if paused then "  PAUSED" else "");
               (match sync |> member "state" with
                 | `String "hold" ->
                     say "    sync held: %s"
                       (sync |> member "reason" |> to_string_option
                      |> Option.value ~default:"")
                 | _ -> ());
               let n = int_field queues "pendingFiles" in
               if n > 0 then say "    %d uploads pending" n;
               let n = int_field queues "pendingMetadata" in
               if n > 0 then say "    %d metadata changes pending" n))
           (report |> member "domains" |> to_list);
         processes report);
      0)

let status_cmd =
  let json =
    Arg.(value & flag & info ["json"] ~doc:"Print the report as JSON.")
  in
  cmd "status" ~doc:"Report what tsync is doing."
    Term.(const status $ json $ verbose)

let cmds = [status_cmd]
