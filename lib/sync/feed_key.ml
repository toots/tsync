type t = string

let parse s =
  let s = String.trim s in
  let last =
    match String.rindex_opt s '/' with
      | Some i -> String.sub s (i + 1) (String.length s - i - 1)
      | None -> s
  in
  if
    String.length last > 14
    && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub last 0 13)
    && last.[13] = '-'
    && not (String.contains last '/')
  then Some last
  else None

let to_string k = k
let ms k = Int64.of_string (String.sub k 0 13)
let client k = String.sub k 14 (String.length k - 14)
let compare = String.compare
let equal = String.equal

let month k =
  let tm = Unix.gmtime (Int64.to_float (ms k) /. 1000.) in
  Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)

let make ~ms ~client = Printf.sprintf "%013Ld-%s" ms client

(* 03 §2.2: only the owner mints, never re-using a
   millisecond even across a backward clock step. *)
type minter = { client_id : string; m : Mutex.t; mutable last : int64 }

let minter ~client ~seen =
  let last =
    List.fold_left (fun acc k -> if ms k > acc then ms k else acc) 0L seen
  in
  { client_id = client; m = Mutex.create (); last }

let mint t =
  Mutex.protect t.m (fun () ->
      let now = Int64.of_float (Unix.gettimeofday () *. 1000.) in
      let v = if now > t.last then now else Int64.succ t.last in
      t.last <- v;
      make ~ms:v ~client:t.client_id)
