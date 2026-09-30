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

(* failure-model §7.5: a classified failure prints its sentence, never a
   trace. *)
(* Every process leases its uplinks from the supervisor; the supervisor itself
   takes ownership in place of this. *)
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

let verbose =
  Arg.(value & flag & info ["v"; "verbose"] ~doc:"Log at info level.")

let set_verbose v = if v then Atomic.set Log.min_level Log.Info

let domain_arg =
  Arg.(
    value
    & opt (some string) None
    & info ["d"; "domain"] ~docv:"NAME" ~doc:"The domain to act on.")

let cmd name ~doc term = Cmd.v (Cmd.info name ~doc) term
