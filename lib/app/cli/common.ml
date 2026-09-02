open Cmdliner

let verbose = ref false

(* Progress goes through Log at info level, which --verbose reveals. Command
   results stay on stdout via Printf. *)
let set_verbose v =
  verbose := v;
  Log.set_min_level (if v then `info else `warn)

let vprintf fmt = Log.info fmt

let verbose_arg =
  Arg.(value & flag & info ["verbose"; "v"] ~doc:"Print detailed progress")

let runtime_paths = Runtime.default_paths ()
let mount_point_of = Conf_parsing.mount_point_of
let frontend_names = Daemons.frontend_names
let resolve_frontend = Daemons.frontend_for

let load_config () = Conf_parsing.load runtime_paths.Runtime.config_path

let domain_names cfg =
  List.map
    (fun (d : Conf_parsing.domain) -> d.Conf_parsing.name)
    cfg.Conf_parsing.domains

(* The config is read when the shell asks rather than when the term is built,
   a term being built before the command knows it will need one, and a caller
   with no config gets no names rather than an error on every keystroke. *)
let complete_domain_name _ ~token =
  match domain_names (load_config ()) with
    | names ->
        Ok
          (List.filter_map
             (fun n ->
               if String.starts_with ~prefix:token n then
                 Some (Arg.Completion.string n)
               else None)
             names)
    | exception _ -> Ok []

let domain_name_conv =
  Arg.Conv.of_conv Arg.string
    ~completion:(Arg.Completion.make complete_domain_name)

let domain_arg =
  Arg.(
    value
    & opt (some domain_name_conv) None
    & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")

(* Conduit picks its TLS backend once per process, so it is set here rather
   than inside a per-domain constructor. *)
let make_conf ?domain ?socket_path ?resume cfg =
  Tls_conf.apply cfg.Conf_parsing.tls;
  Domain.of_config ?domain ?socket_path ?resume ~paths:runtime_paths cfg

let load_conf ?domain () = make_conf ?domain (load_config ())
let reading_from = Domain.reading_from
let read_default_domain () = Domain.default_domain ~paths:runtime_paths
let default_domain_file () = Domain.default_domain_file ~paths:runtime_paths

let domain_target ?domain () =
  Domain.target ?domain ~paths:runtime_paths (load_config ())

let domain_socket ?domain () = snd (domain_target ?domain ())

let domain_socket_for_path path =
  Daemons.socket_for_path ~paths:runtime_paths (load_config ()) path

(* [tsync start --mount] moves the mount without touching the config, and only
   ever for a lone domain ({!Cmd_start}), so a path under one belongs to that
   domain and the running daemon is the only thing that knows where it put it. *)
let mounted_elsewhere ?domain cfg path =
  let name, socket_path = Domain.target ?domain ~paths:runtime_paths cfg in
  let field k = function `Assoc o -> List.assoc_opt k o | _ -> None in
  let mount =
    match Ipc.action ~socket_path ~domain:name "stats" with
      | fields -> (
          match field "domains" (`Assoc fields) with
            | Some (`List (d :: _)) -> (
                match field "frontends" d with
                  | Some (`List fs) ->
                      List.find_map
                        (fun f ->
                          match field "mountPoint" f with
                            | Some (`String p) when p <> "" -> Some p
                            | _ -> None)
                        fs
                  | _ -> None)
            | _ -> None)
      | exception _ -> None
  in
  match mount with
    | Some m when String.starts_with ~prefix:(m ^ "/") path ->
        Some
          ( name,
            String.sub path
              (String.length m + 1)
              (String.length path - String.length m - 1) )
    | _ -> None

(* A path a user typed, named the way the daemon knows it. Resolved on this side
   because this side knows where the mirror is: the folder markers say which id
   holds the item, so the request carries a reference and the daemon has one way
   to be told which item it is about.

   The kind is not asked for. Every part of the key this reads — its path, its
   leaf, its parent — is the same whichever it is, and whether a marker exists
   is what says the item is a folder. *)
let item_for_path ?domain path =
  let cfg = load_config () in
  let found =
    match Daemons.domain_for_path ?domain ~paths:runtime_paths cfg path with
      | Some (d, rel) -> Some (d.Conf_parsing.name, rel)
      | None -> mounted_elsewhere ?domain cfg path
  in
  match found with
    | None -> Error (path ^ ": under no domain this machine serves")
    | Some (name, rel) -> (
        let (module C : Conf_lwt.S) = make_conf ~domain:name cfg in
        let module Lk = Logical_key.Make (C) in
        let found =
          Oneshot.run
            (Folder_ids_lwt.ref_of_key ~cache_root:C.cache_root
               ~domain_name:C.domain_name (Lk.file rel))
        in
        match found with
          | Some item -> Ok (C.domain_name, item)
          | None -> Error (path ^ ": this client has not resolved its folder"))

let domain_targets () = Daemons.all ~paths:runtime_paths (load_config ())

(* What the deferred targets still owe, summed: whether work is outstanding is
   the question, and which target holds it is answered by [tsync status]'s own
   per-backend listing. [None] where no target defers at all, so a domain
   writing straight through reports no queue rather than an empty one. *)
let deferred_totals members =
  let sum f =
    List.fold_left
      (fun acc m -> acc + match f m with Some g -> g () | None -> 0)
      0 members
  in
  if not (List.exists (fun m -> m.Backend.pending <> None) members) then None
  else
    Some
      ( sum (fun m -> m.Backend.pending),
        sum (fun m -> m.Backend.in_flight),
        List.exists
          (fun m ->
            match m.Backend.degraded with Some g -> g () | None -> false)
          members )

(* The half of a job report that is every command's alike: where to send it,
   which domain it belongs to, and what that domain's targets still owe. A
   command passes only what is its own.

   It goes to the process converging the domains, which is the one place on the
   machine that always answers: a domain need not have a frontend with a socket
   of its own, and one served only by the http-proxy has none. Reporting must
   never decide whether a command runs, so nothing listening is silence in
   [tsync status] rather than a failure.

   [current] joins a phase to the thing within it, so six commands do not each
   pick a separator. *)
let report_job ?target ?current ~kind (module C : Conf_lwt.S) ~counters () =
  Job_report_lwt.start
    ~socket_path:(Runtime.sync_socket_path runtime_paths)
    ~domain:C.domain_name ~kind ?target ?current
    ~deferred:(fun () -> deferred_totals C.members)
    ~counters ()

let doing phase detail = phase ^ " · " ^ detail
let human_bytes = Metrics.human_bytes

let human_ts ts_ns =
  let secs = Int64.to_float (Int64.div ts_ns 1_000_000_000L) in
  let tm = Unix.localtime secs in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let parse_duration s =
  let n = String.length s in
  let fail () =
    failwith ("invalid duration (use <N>d, <N>h, <N>m or <N>s): " ^ s)
  in
  if n < 2 then fail ()
  else (
    match (int_of_string_opt (String.sub s 0 (n - 1)), s.[n - 1]) with
      | Some k, 'd' when k > 0 -> float_of_int (k * 86400)
      | Some k, 'h' when k > 0 -> float_of_int (k * 3600)
      | Some k, 'm' when k > 0 -> float_of_int (k * 60)
      | Some k, 's' when k > 0 -> float_of_int k
      | _ -> fail ())

let run_lwt = Oneshot.run
