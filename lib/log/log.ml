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

let log level fmt =
  if rank level >= rank !min_level then
    Printf.ksprintf (fun msg -> !active level (!prefix ^ msg)) fmt
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
