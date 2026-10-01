open Cmdliner
open Tsync_core
open Tsync_ipc
open Tsync_config

exception Exit_with of int

let say fmt = Printf.printf (fmt ^^ "\n%!")

let fail fmt =
  Printf.ksprintf
    (fun m ->
      prerr_endline ("tsync: " ^ m);
      raise (Exit_with 1))
    fmt

let config_opt () =
  Option.map
    (fun s -> try Config.of_string s with Config.Invalid e -> fail "%s" e)
    (Paths.read_config ())

let config () =
  match config_opt () with
    | Some c -> c
    | None -> fail "no config at %s" (Paths.config_file ())

let domain ?name config =
  let default =
    match Paths.default_domain () with
      | Some d when Config.find_domain config d = None ->
          Log.warn "the default domain %s is not configured; ignoring it" d;
          None
      | d -> d
  in
  try Config.resolve ?name ?default config
  with Config.Invalid e -> fail "%s" e

(* Every process leases its uplinks from the supervisor, which takes ownership
   in place of this.

   failure-model §7.5: a classified failure prints its sentence, never a trace. *)
let run body =
  Printexc.record_backtrace true;
  Tsync_store.Uplink.lease (fun request ->
      Tsync_store.Uplink_lease.(
        answer_of_json
          (Ipc.call ~timeout:1.
             (Paths.supervisor_socket ())
             (request_to_json request))));
  match Rt.run_sync body with
    | code -> code
    | exception Exit_with code -> code
    | exception Config.Invalid e ->
        prerr_endline ("tsync: " ^ e);
        1
    | exception e ->
        let f = Fail.classify e in
        prerr_endline
          ("tsync: " ^ f.reason
          ^ Option.fold ~none:"" ~some:(fun r -> " (" ^ r ^ ")") f.repair);
        if f.kind = Fail.Unexplained then 125 else 1

(* security §9: [--tls] wins over the config's [tls]; OpenSSL otherwise. *)
let use_tls (config : Config.t) tls =
  match Option.fold ~none:config.tls ~some:Option.some tls with
    | None -> ()
    | Some name -> (
        match Tsync_http.Transport.tls_impl_of_string name with
          | Some impl -> Atomic.set Tsync_http.Transport.tls_impl impl
          | None ->
              fail "unknown TLS implementation %S (native or openssl)" name)

(* 07 §5.1: every command takes both, so the display is set from here. *)
let verbose =
  let verbose =
    Arg.(
      value & flag
      & info ["v"; "verbose"]
          ~doc:
            "Narrate each step and decision on stderr, and log at info level.")
  and quiet =
    Arg.(
      value & flag
      & info ["q"; "quiet"] ~doc:"Show no progress or narration while running.")
  in
  Term.(
    const (fun verbose quiet ->
        Display.configure ~verbose ~quiet;
        verbose && not quiet)
    $ verbose $ quiet)

let set_verbose v = if v then Atomic.set Log.min_level Log.Info

(* 07 §5.1: <N>d|h|m|s with N > 0, in seconds. *)
let duration =
  let parse s =
    let n = String.length s in
    let unit_ = if n > 0 then Some s.[n - 1] else None in
    match (unit_, int_of_string_opt (String.sub s 0 (max 0 (n - 1)))) with
      | Some u, Some v when v > 0 -> (
          match u with
            | 'd' -> Ok (float v *. 86400.)
            | 'h' -> Ok (float v *. 3600.)
            | 'm' -> Ok (float v *. 60.)
            | 's' -> Ok (float v)
            | _ -> Error (`Msg (s ^ ": a duration is <N>d, <N>h, <N>m or <N>s"))
          )
      | _ -> Error (`Msg (s ^ ": a duration is <N>d, <N>h, <N>m or <N>s"))
  in
  Arg.conv (parse, fun f s -> Format.fprintf f "%.0fs" s)

let domain_arg =
  Arg.(
    value
    & opt (some string) None
    & info ["d"; "domain"] ~docv:"NAME" ~doc:"The domain to act on.")

let cmd name ~doc term = Cmd.v (Cmd.info name ~doc) term

let job ?name verbose job =
  let config = config () in
  let dom = domain ?name config in
  let socket = Tsync_config.Paths.owner_socket dom.name in
  Tsync_owner.Owner.request
    ~what:("tsync " ^ Tsync_owner.Jobs.kind job)
    config dom
    ~on_line:(function
      | Started id ->
          Rt.spawn ~name:"cancel" (fun () ->
              Stop.wait ();
              prerr_endline
                "tsync: cancelling; the job stops at its next unit boundary";
              try
                ignore
                  (Tsync_owner.Protocol.call socket
                     (Tsync_owner.Protocol.Cancel id))
              with e -> Log.warn "cannot cancel: %s" (Printexc.to_string e))
      | line -> Tsync_owner.Handler.print_line line)
    (Tsync_owner.Protocol.Job { job; narrate = verbose })

(* Before the runtime starts, so every thread inherits the mask. *)
let run_job ?name verbose j =
  set_verbose verbose;
  Tsync_owner.Owner.stop_on_signals
    ~second:(fun () ->
      prerr_endline "tsync: interrupted again; exiting now";
      Unix._exit 130)
    ();
  run (fun () -> job ?name verbose j)
