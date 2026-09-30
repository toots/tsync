open Cmdliner
open Tsync_core
open Tsync_ipc
open Tsync_config
open Cli
module R = Tsync_status.Status_report

let answer socket domain =
  match
    Ipc.call socket
      (`Assoc
         ([("action", `String "stats"); ("arg", `String "frontend")]
         @ Option.fold ~none:[] ~some:(fun d -> [("domain", `String d)]) domain
         ))
  with
    | `Assoc l as reply when List.assoc_opt "ok" l = Some (`Bool true) ->
        R.answer_of_yojson reply
    | reply ->
        Error (Option.value ~default:"no answer" (Ipc.field reply "error"))
    | exception e -> Error (Fail.classify e).reason

let process ~role ~serves = function
  | Ok (a : R.answer) ->
      {
        R.role;
        pid = Some a.self.server.pid;
        serves;
        error = None;
        self = Some a.self;
      }
  | Error e -> { R.role; pid = None; serves; error = Some e; self = None }

(* 07 §5.5 step 3: with no supervisor, every owner and the store server
   answer for themselves. *)
let fold_owners config : R.machine =
  let domains = match config with Some c -> c.Config.domains | None -> [] in
  let owners =
    Rt.map_concurrently
      (fun (d : Config.domain) ->
        let name = Domain_name.to_string d.name in
        (name, answer (Paths.owner_socket d.name) (Some name)))
      domains
  in
  let server = answer (Paths.store_server_socket ()) None in
  {
    host = Unix.gethostname ();
    domains =
      List.concat_map
        (fun (name, a) ->
          match a with
            | Ok (x : R.answer) -> x.domains
            | Error _ -> [R.Unanswered name])
        owners;
    processes =
      (List.map (fun (name, a) -> process ~role:"owner" ~serves:[name] a) owners
      @
        match server with
        | Ok _ -> [process ~role:"store-server" ~serves:[] server]
        | Error _ -> []);
    uplinks = [];
    jobs = [];
    warnings = [];
  }

let report config =
  match
    Ipc.call (Paths.supervisor_socket ()) (`Assoc [("action", `String "stats")])
  with
    | reply -> (
        match R.machine_of_yojson reply with
          | Ok m -> m
          | Error e -> fail "the supervisor's report is unreadable: %s" e)
    | exception Ipc.Not_serving _ -> fold_owners config

(* 07 §5.5: targets are resolved once, so a [-w] redraw does not re-read the
   config. *)
let status json watch verbose =
  set_verbose verbose;
  run (fun () ->
      let config = config_opt () in
      let print () =
        let m = report config in
        if json then
          print_endline
            (Yojson.Safe.pretty_to_string
               (match R.machine_to_yojson m with
                 | `Assoc l -> `Assoc (("t", `Float (Unix.gettimeofday ())) :: l)
                 | j -> j))
        else
          print_string
            (Tsync_status.Status_text.render ~now:(Unix.gettimeofday ()) m)
      in
      match watch with
        | Some period when not json ->
            let rec loop () =
              print_string "\027[H\027[2J";
              print ();
              flush stdout;
              Rt.sleep period;
              loop ()
            in
            loop ()
        | _ ->
            print ();
            0)

let status_cmd =
  let json = Arg.(value & flag & info ["json"] ~doc:"Print the report as JSON.")
  and watch =
    Arg.(
      value
      & opt (some float) None
      & info ["w"; "watch"] ~docv:"S" ~doc:"Redraw every $(docv) seconds.")
  in
  cmd "status" ~doc:"Report what tsync is doing."
    Term.(const status $ json $ watch $ verbose)

let cmds = [status_cmd]
