open Lwt.Syntax

type t = { known : (string, unit) Hashtbl.t; max_known : unit -> int }

let create ?(max_known = fun () -> 100_000) () =
  { known = Hashtbl.create 4096; max_known }

let remember t key =
  if Hashtbl.length t.known >= t.max_known () then Hashtbl.reset t.known;
  Hashtbl.replace t.known key ()

let count t = Hashtbl.length t.known

let known t ~corrupt ~present key =
  let* marked = corrupt key in
  if marked then Lwt.return_false
  else if Hashtbl.mem t.known key then Lwt.return_true
  else present key
