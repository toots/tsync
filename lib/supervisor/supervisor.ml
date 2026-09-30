open Tsync_core
open Tsync_ipc
open Tsync_config

type child = { args : string list; domains : string list; socket : string }

let reap_margin = 2.
let reap_poll = 0.05
let backoff_min = 1.
let backoff_max = 60.
let restart_stable = 60.
let job_stale_min = 45.
let job_report_interval = 10.
let job_keep = 300.

let presenting (d : Config.domain) =
  List.find_map
    (fun (f : Config.frontend) ->
      Option.bind (Frontend.find f.ftype) (fun (r : Frontend.t) -> r.presenting))
    d.frontends

let assign ?mount ?tls (config : Config.t) =
  let tls_args = Option.fold ~none:[] ~some:(fun t -> ["--tls"; t]) tls in
  let extra =
    Option.fold ~none:[] ~some:(fun m -> ["--mount"; m]) mount @ tls_args
  in
  let owner names =
    {
      args =
        ("owner" :: List.concat_map (fun n -> ["--domain"; n]) names) @ extra;
      domains = names;
      socket =
        Paths.owner_socket
          (Domain_name.v (match names with n :: _ -> n | [] -> ""));
    }
  in
  let name (d : Config.domain) = Domain_name.to_string d.name in
  let shared, own =
    List.partition (fun d -> presenting d = Some `Shared) config.domains
  in
  let served =
    List.filter (fun d -> Config.frontend d "http-proxy" <> None) config.domains
  in
  List.map (fun d -> owner [name d]) own
  @ (if shared = [] then [] else [owner (List.map name shared)])
  @
  if served = [] then []
  else
    [
      {
        args = "store-server" :: tls_args;
        domains = List.map name served;
        socket = Paths.store_server_socket ();
      };
    ]

type running = {
  child : child;
  mutable pid : int option;
  mutable started : float;
  mutable restart_at : float;
  mutable backoff : float;
}

let spawn exe r =
  let pid =
    Unix.create_process exe
      (Array.of_list (exe :: r.child.args))
      Unix.stdin Unix.stdout Unix.stderr
  in
  Log.info "started %s (pid %d)" (String.concat " " r.child.args) pid;
  r.pid <- Some pid;
  r.started <- Rt.now ()

let signal_name s =
  Option.value ~default:(string_of_int s)
    (List.assoc_opt s
       Sys.
         [
           (sigkill, "SIGKILL");
           (sigterm, "SIGTERM");
           (sigint, "SIGINT");
           (sigsegv, "SIGSEGV");
           (sigabrt, "SIGABRT");
           (sigbus, "SIGBUS");
           (sighup, "SIGHUP");
         ])

let describe_status = function
  | Unix.WEXITED n -> Printf.sprintf "exit status %d" n
  | WSIGNALED s -> signal_name s
  | WSTOPPED s -> "stopped by " ^ signal_name s

(* 07 §3.3: the backoff doubles until a child stays up for [restart_stable]. *)
let reap_one r =
  match r.pid with
    | None -> ()
    | Some pid -> (
        match Unix.waitpid [WNOHANG] pid with
          | 0, _ -> ()
          | _, status ->
              r.pid <- None;
              if Rt.now () -. r.started >= restart_stable then
                r.backoff <- backoff_min;
              let what = String.concat " " r.child.args in
              if Stop.requested () then
                Log.info "%s stopped (%s)" what (describe_status status)
              else
                Log.f
                  (if status = WEXITED Tsync_owner.Owner.owner_held then
                     Log.Info
                   else Log.Warn)
                  "%s ended (%s); restarting in %.0fs" what
                  (describe_status status) r.backoff;
              r.restart_at <- Rt.now () +. r.backoff;
              r.backoff <- Float.min backoff_max (2. *. r.backoff)
          | exception Unix.Unix_error (ECHILD, _, _) -> r.pid <- None)

let supervise exe children =
  try
    while true do
      List.iter
        (fun r ->
          reap_one r;
          if
            r.pid = None && Rt.now () >= r.restart_at && not (Stop.requested ())
          then (
            try spawn exe r
            with e -> Log.err "cannot start %s: %s" exe (Printexc.to_string e)))
        children;
      Stop.sleep 0.5
    done
  with Stop.Stopping -> ()

(* 07 §3.4: every child is told at once, then reaped until the grace and the
   margin have passed, then killed. *)
let stop_children children =
  let signal s =
    List.iter
      (fun r ->
        Option.iter (fun pid -> try Unix.kill pid s with _ -> ()) r.pid)
      children
  in
  signal Sys.sigterm;
  let deadline = Rt.now () +. Stop.grace +. reap_margin in
  let alive () = List.exists (fun r -> r.pid <> None) children in
  while alive () && Rt.now () < deadline do
    List.iter reap_one children;
    if alive () then Rt.sleep reap_poll
  done;
  if alive () then (
    Log.warn "children still running after %.0fs; killing them"
      (Stop.grace +. reap_margin);
    signal Sys.sigkill;
    List.iter
      (fun r ->
        Option.iter
          (fun pid -> try ignore (Unix.waitpid [] pid) with _ -> ())
          r.pid;
        r.pid <- None)
      children)

type job = {
  report : Ipc.json;
  key : string;
  running : bool;
  at : float;
  pid : int;
}

let jobs = Atomic.make []

let record_job req =
  let get k = Option.value ~default:"" (Ipc.field req k) in
  let pid =
    match req with
      | `Assoc l -> (
          match List.assoc_opt "pid" l with Some (`Int p) -> p | _ -> 0)
      | _ -> 0
  in
  let key = Printf.sprintf "%d %s %s" pid (get "kind") (get "domain") in
  let j =
    {
      report = req;
      key;
      running = get "state" = "running";
      at = Rt.now ();
      pid;
    }
  in
  let rec swap () =
    let old = Atomic.get jobs in
    if
      not
        (Atomic.compare_and_set jobs old
           (j :: List.filter (fun o -> o.key <> key) old))
    then swap ()
  in
  swap ()

(* 07 §4.6: a running job whose pid is gone expires; a finished one is kept for
   [job_keep]. *)
let live_jobs () =
  let now = Rt.now () in
  List.filter
    (fun j ->
      if j.running then
        now -. j.at < Float.max job_stale_min (4. *. job_report_interval)
        || Fs.pid_alive j.pid
      else now -. j.at < job_keep)
    (Atomic.get jobs)

let ask_stats arg r =
  List.map
    (fun d ->
      match
        Ipc.call ~timeout:Ipc.request_deadline r.child.socket
          (`Assoc
             [
               ("action", `String "stats");
               ("domain", `String d);
               ("arg", `String (String.concat "," ("frontend" :: arg)));
             ])
      with
        | `Assoc l when List.assoc_opt "ok" l = Some (`Bool true) ->
            let bodies =
              match List.assoc_opt "domains" l with
                | Some (`List ds) -> ds
                | _ -> []
            in
            Ok (bodies, List.assoc_opt "process" l)
        | reply ->
            Error (Option.value ~default:"no answer" (Ipc.field reply "error"))
        | exception e -> Error (Printexc.to_string e))
    r.child.domains
  |> List.map2 (fun d res -> (d, res)) r.child.domains

let machine_report arg children =
  let answers = Rt.map_concurrently (ask_stats arg) children in
  let domains =
    List.concat_map
      (List.concat_map (fun (d, res) ->
           match res with
             | Ok (bodies, _) -> bodies
             | Error _ ->
                 [`Assoc [("name", `String d); ("unanswered", `Bool true)]]))
      answers
  in
  let processes =
    `Assoc
      [
        ("pid", `Int (Unix.getpid ()));
        ("role", `String "supervisor");
        ("serves", `List []);
        ("process", Usage.to_json (Usage.sample ()));
      ]
    :: List.map2
         (fun r ans ->
           let base =
             [
               ( "role",
                 `String
                   (match r.child.args with
                     | "store-server" :: _ -> "store-server"
                     | _ -> "owner") );
               ("serves", `List (List.map (fun d -> `String d) r.child.domains));
               ("socketPath", `String r.child.socket);
             ]
             @ Option.fold ~none:[] ~some:(fun p -> [("pid", `Int p)]) r.pid
             @ Option.to_list
                 (List.find_map
                    (function
                      | _, Ok (_, Some p) -> Some ("process", p) | _ -> None)
                    ans)
           in
           match
             List.find_map
               (fun (_, res) ->
                 Result.fold ~ok:(fun _ -> None) ~error:Option.some res)
               ans
           with
             | None -> `Assoc (("reachable", `Bool true) :: base)
             | Some e ->
                 `Assoc
                   (("reachable", `Bool false) :: ("error", `String e) :: base))
         children answers
  in
  Ipc.ok
    [
      ("host", `String (Unix.gethostname ()));
      ("domains", `List domains);
      ("processes", `List processes);
      ("uplinks", Tsync_store.Uplink.status ());
      ("jobs", `List (List.map (fun j -> j.report) (live_jobs ())));
      ( "warnings",
        `List
          (List.map
             (fun (t, lvl, msg) ->
               `Assoc
                 [
                   ("t", `Float t);
                   ("level", `String (Log.name lvl));
                   ("message", `String msg);
                 ])
             (Log.recent ())) );
    ]

let handle children req =
  match Ipc.field req "action" with
    | Some "ping" -> Ipc.Reply (Ipc.ok [])
    | Some "stop" ->
        Stop.request ();
        Ipc.Reply (Ipc.ok [])
    | Some "stats" ->
        let arg =
          List.filter (( <> ) "")
            (String.split_on_char ','
               (Option.value ~default:"" (Ipc.field req "arg")))
        in
        Ipc.Reply (machine_report arg children)
    | Some "report" ->
        record_job req;
        Ipc.Reply (Ipc.ok [])
    | Some "uplink" -> (
        match Tsync_store.Uplink.renewal req with
          | Some answer -> Ipc.Reply answer
          | None ->
              Ipc.Reply (Ipc.failure (Fail.make Fail.Invalid "not a renewal")))
    | Some a ->
        Ipc.Reply
          (Ipc.failure (Fail.make Fail.Invalid ("unknown action: " ^ a)))
    | None -> Ipc.Reply (Ipc.failure (Fail.make Fail.Invalid "no action"))

let run ~exe (config : Config.t) children =
  let path = Paths.supervisor_socket () in
  match
    Ipc.call ~timeout:Ipc.advisory_deadline path
      (`Assoc [("action", `String "ping")])
  with
    | _ ->
        prerr_endline "tsync is already running";
        1
    | exception _ -> (
        let children =
          List.map
            (fun child ->
              {
                child;
                pid = None;
                started = 0.;
                restart_at = 0.;
                backoff = backoff_min;
              })
            children
        in
        match Ipc.serve ~path (handle children) with
          | exception e ->
              Log.err "cannot serve %s: %s" path (Printexc.to_string e);
              2
          | server ->
              Tsync_store.Uplink.own
                ~state_file:(Filename.concat (Paths.data_dir ()) "uplink.json")
                (fun link ->
                  Config.uplink_settings (Config.link_settings config link));
              supervise exe children;
              stop_children children;
              Ipc.close server;
              0)
