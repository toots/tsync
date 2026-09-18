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
let domain_targets () = Daemons.all ~paths:runtime_paths (load_config ())

(* Each store a job's bytes can cross a link to, with what it owes: a local tree
   has no traffic and defers nothing, so it is left out rather than zeroed. *)
let linked_backends members =
  List.filter_map
    (fun m ->
      match Backend.link_json m with
        | [] -> None
        | fields -> Some (`Assoc (("name", `String m.Backend.name) :: fields)))
    members

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
    ~backends:(fun () -> linked_backends C.members)
    ~counters ()

let doing phase detail = phase ^ " · " ^ detail

let terminal_width () =
  let from_tput () =
    match Unix.open_process_in "tput cols 2>/dev/null" with
      | ic ->
          let cols = try int_of_string_opt (input_line ic) with _ -> None in
          ignore (Unix.close_process_in ic);
          cols
      | exception _ -> None
  in
  match Option.bind (Sys.getenv_opt "COLUMNS") int_of_string_opt with
    | Some cols -> cols
    | None -> Option.value (from_tput ()) ~default:80

(* Cut on a character rather than a byte, a name being UTF-8 and half of one
   being what a terminal prints as garbage.

   ponytail: counts code points, so a line of wide characters still wraps;
   measure display width if names in such scripts ever matter here. *)
let fit ~width line =
  let is_start c = Char.code c land 0xC0 <> 0x80 in
  let rec cut i seen =
    if i >= String.length line then None
    else if is_start line.[i] && seen = width - 1 then Some i
    else cut (i + 1) (if is_start line.[i] then seen + 1 else seen)
  in
  match cut 0 0 with
    | Some i when width > 1 -> String.sub line 0 i ^ "…"
    | _ -> line

type live = {
  watching : bool;  (** whether anybody is: stderr is a terminal *)
  block : string list -> unit;  (** lines that rewrite themselves in place *)
  note : string -> unit;  (** a line that stays, above whatever rewrites *)
  clear : unit -> unit;  (** before anything that must stay *)
}

(* Progress that rewrites itself belongs on a terminal; down a pipe it is
   padding in front of the summary, so the same text goes to the log there,
   which is what [-v] reaches. *)
let live_output () =
  let watching = Unix.isatty Unix.stderr in
  let width = if watching then terminal_width () else max_int in
  let drawn = ref 0 in
  let rewind () =
    if !drawn > 1 then Printf.eprintf "\027[%dA" (!drawn - 1);
    if !drawn > 0 then Printf.eprintf "\r\027[J"
  in
  let clear () =
    if watching then begin
      rewind ();
      drawn := 0;
      flush stderr
    end
  in
  let block lines =
    if not watching then List.iter (fun line -> vprintf "%s" line) lines
    else begin
      rewind ();
      prerr_string (String.concat "\n" (List.map (fit ~width) lines));
      drawn := List.length lines;
      flush stderr
    end
  in
  let note line =
    if not watching then vprintf "%s" line
    else begin
      clear ();
      prerr_endline line
    end
  in
  { watching; block; note; clear }

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
