type level = [ `debug | `info | `warn | `err ]

let rank = function `debug -> 0 | `info -> 1 | `warn -> 2 | `err -> 3

(* Messages below this level are dropped. *)
let min_level : level ref = ref `info
let set_min_level l = min_level := l

(* The active sink receives the level and the fully formatted message. Defaults
   to stderr; a caller (e.g. the daemon) can swap it. *)
let active : (level -> string -> unit) ref = ref Log_printf.log
let use sink = active := sink

(* Built-in sink: timestamped, colorized lines on stderr. *)
let printf = Log_printf.log

(* Prepended to every message — set per-process to a domain name so per-domain
   daemon processes are distinguishable in a shared journal. *)
let prefix = ref ""
let set_prefix p = prefix := p

(* The last few warnings and errors, kept so a process with no other window into
   itself (the http-proxy frontend, which has no IPC socket) can report what went
   wrong lately. Only what actually reached the sink is remembered. *)
let max_recent = 50
let recent_q : (float * level * string) Queue.t = Queue.create ()

let remember level msg =
  if rank level >= rank `warn then begin
    Queue.add (Unix.gettimeofday (), level, msg) recent_q;
    if Queue.length recent_q > max_recent then ignore (Queue.pop recent_q)
  end

let recent () = List.rev (List.of_seq (Queue.to_seq recent_q))

let log level fmt =
  if rank level >= rank !min_level then
    Printf.ksprintf
      (fun msg ->
        let msg = !prefix ^ msg in
        remember level msg;
        !active level msg)
      fmt
  else Printf.ifprintf () fmt

let debug fmt = log `debug fmt
let info fmt = log `info fmt
let warn fmt = log `warn fmt
let err fmt = log `err fmt

(* Preset for the daemon: log to syslog when the library is available, else fall
   back to stderr. Logs at debug so the full detail reaches the journal. *)
module Daemon = struct
  let available = Log_syslog_provider.available
  let implementation = if available then "syslog" else "printf"

  let init () =
    set_min_level `debug;
    if available then (
      Log_syslog_provider.init ();
      use Log_syslog_provider.log)
    else Log_printf.init ()
end
