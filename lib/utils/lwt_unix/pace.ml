type t = { interval : float; last : (string, float) Hashtbl.t }

let default_interval = 1.

let create ?(interval = default_interval) () =
  { interval; last = Hashtbl.create 4 }

let fire t ?(key = "") ?(force = false) f =
  let now = Unix.gettimeofday () in
  let previous =
    Option.value (Hashtbl.find_opt t.last key) ~default:neg_infinity
  in
  if force || now -. previous >= t.interval then begin
    Hashtbl.replace t.last key now;
    f ()
  end
