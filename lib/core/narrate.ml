type t = { say : string -> unit; progress : ?fraction:float -> string -> unit }

let none = { say = ignore; progress = (fun ?fraction:_ _ -> ()) }
let say t fmt = Printf.ksprintf t.say fmt
let progress t ?fraction fmt = Printf.ksprintf (t.progress ?fraction) fmt

let count ?plural n noun =
  Printf.sprintf "%d %s" n
    (if n = 1 then noun
     else (match plural with Some p -> p | None -> noun ^ "s"))

let duration s =
  let s = int_of_float (Float.max 0. s) in
  if s < 3600 then Printf.sprintf "%dm %ds" (s / 60) (s mod 60)
  else if s < 86400 then Printf.sprintf "%dh %dm" (s / 3600) (s mod 3600 / 60)
  else Printf.sprintf "%dd %dh" (s / 86400) (s mod 86400 / 3600)

let size_of_float b =
  if b < 1024. then Printf.sprintf "%.0f B" b
  else (
    let rec go b = function
      | [u] -> Printf.sprintf "%.1f %s" b u
      | u :: rest ->
          if b < 1024. then Printf.sprintf "%.1f %s" b u
          else go (b /. 1024.) rest
      | [] -> assert false
    in
    go (b /. 1024.) ["KiB"; "MiB"; "GiB"; "TiB"])

let size n = size_of_float (float_of_int n)
let rate b = size_of_float b ^ "/s"

let date t =
  let tm = Unix.localtime t in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
    tm.tm_mday tm.tm_hour tm.tm_min
