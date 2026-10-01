type t = string -> unit

let none _ = ()

let stderr line =
  let tm = Unix.localtime (Unix.gettimeofday ()) in
  prerr_endline
    (Printf.sprintf "%02d:%02d:%02d %s" tm.tm_hour tm.tm_min tm.tm_sec line)

let say t fmt = Printf.ksprintf t fmt

let periodic ?(every = 10.) t =
  let last = Atomic.make (Unix.gettimeofday ()) in
  fun line ->
    let now = Unix.gettimeofday () in
    let prev = Atomic.get last in
    if now -. prev >= every && Atomic.compare_and_set last prev now then
      t (line ())

let count ?plural n noun =
  Printf.sprintf "%d %s" n
    (if n = 1 then noun
     else (match plural with Some p -> p | None -> noun ^ "s"))

let duration s =
  let s = int_of_float s in
  if s < 60 then Printf.sprintf "%ds" s
  else if s < 3600 then Printf.sprintf "%dm%02ds" (s / 60) (s mod 60)
  else Printf.sprintf "%dh%02dm" (s / 3600) (s / 60 mod 60)

let size n =
  let f = float_of_int n in
  if n < 1024 then Printf.sprintf "%d B" n
  else if f < 1048576. then Printf.sprintf "%.1f KiB" (f /. 1024.)
  else if f < 1073741824. then Printf.sprintf "%.1f MiB" (f /. 1048576.)
  else Printf.sprintf "%.1f GiB" (f /. 1073741824.)

let date t =
  let tm = Unix.localtime t in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
    tm.tm_mday tm.tm_hour tm.tm_min
