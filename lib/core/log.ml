type level = Debug | Info | Warn | Err

let rank = function Debug -> 0 | Info -> 1 | Warn -> 2 | Err -> 3

let name = function
  | Debug -> "debug"
  | Info -> "info"
  | Warn -> "warn"
  | Err -> "err"

let min_level = Atomic.make Warn
let prefix = Atomic.make ""

let timestamp t =
  let tm = Unix.localtime t in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let stderr_sink level msg =
  Printf.eprintf "%s %s %s\n%!"
    (timestamp (Unix.gettimeofday ()))
    (String.uppercase_ascii (name level))
    msg

let sink = Atomic.make stderr_sink
let recent_m = Mutex.create ()
let recent_q : (float * level * string) Queue.t = Queue.create ()

let recent () =
  Mutex.protect recent_m (fun () ->
      List.rev (List.of_seq (Queue.to_seq recent_q)))

let emit level msg =
  if rank level >= rank Warn then
    Mutex.protect recent_m (fun () ->
        Queue.push (Unix.gettimeofday (), level, msg) recent_q;
        if Queue.length recent_q > 50 then ignore (Queue.pop recent_q));
  if rank level >= rank (Atomic.get min_level) then (
    try (Atomic.get sink) level (Atomic.get prefix ^ msg) with _ -> ())

let f level fmt = Printf.ksprintf (emit level) fmt
let debug fmt = f Debug fmt
let info fmt = f Info fmt
let warn fmt = f Warn fmt
let err fmt = f Err fmt

(* Logs a kind of failure at most once. *)
let once_m = Mutex.create ()
let once_seen = Hashtbl.create 16

let once key level fmt =
  Printf.ksprintf
    (fun msg ->
      if
        Mutex.protect once_m (fun () ->
            if Hashtbl.mem once_seen key then false
            else (
              Hashtbl.replace once_seen key ();
              true))
      then emit level msg)
    fmt

let () =
  (Rt.detached_failure :=
     fun name exn ->
       if exn <> Stop.Stopping then err "%s: %s" name (Printexc.to_string exn));
  Rt.task_error :=
    fun exn bt ->
      err "scheduler task failed: %s\n%s" (Printexc.to_string exn)
        (Printexc.raw_backtrace_to_string bt)
