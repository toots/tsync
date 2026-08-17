(* What the daemon knows about commands running beside it.

   Advisory throughout: a job that never reports is simply absent from a status
   listing, and a row that outlives its process is wrong in a way nobody acts
   on. Nothing here is allowed to affect a running command. *)

type entry = {
  pid : int;
  started : float;
  seen : float;
  report : Yojson.Safe.t;
}

(* Two report intervals plus slack: a job silent for longer has stopped saying
   anything, whatever its pid says. *)
let stale_after = 45.

(* A finished job stays visible this long, so a command that ran between two
   status calls is not invisible in both. *)
let keep_done = 300.

(* Keyed by the job rather than the process: a pid runs one command at a time,
   and a second report from the same pid replaces the first. *)
let table : (int, entry) Hashtbl.t = Hashtbl.create 4

let field name json =
  match json with
    | `Assoc fields -> (
        match List.assoc_opt name fields with Some v -> v | None -> `Null)
    | _ -> `Null

let float_field name json =
  match field name json with
    | `Float f -> f
    | `Int i -> float_of_int i
    | _ -> 0.

(* [ESRCH] is the answer that matters; [EPERM] means a process we may not signal
   and is therefore alive. A pid reused between two reports keeps a stale row
   until [stale_after] retires it, which is why liveness alone is not the test.
*)
let alive pid =
  match Unix.kill pid 0 with
    | () -> true
    | exception Unix.Unix_error (Unix.EPERM, _, _) -> true
    | exception _ -> false

let expired now e =
  let finished =
    match field "state" e.report with
      | `String ("done" | "failed") -> true
      | _ -> false
  in
  if finished then now -. e.seen > keep_done
  else now -. e.seen > stale_after || not (alive e.pid)

(* On write as well as on read: how many rows the table holds is decided by how
   many commands have run, which is not something this code chose. *)
let prune () =
  let now = Unix.gettimeofday () in
  Hashtbl.iter
    (fun pid e -> if expired now e then Hashtbl.remove table pid)
    (Hashtbl.copy table)

let record report =
  match field "pid" report with
    | `Int pid when pid > 0 ->
        prune ();
        Hashtbl.replace table pid
          {
            pid;
            started = float_field "startedAt" report;
            seen = Unix.gettimeofday ();
            report;
          }
    | _ -> ()

(* Oldest first, so a listing reads in the order the jobs started. *)
let live () =
  prune ();
  Hashtbl.fold (fun _ e acc -> e :: acc) table []
  |> List.sort (fun a b -> compare a.started b.started)
  |> List.map (fun e -> e.report)

let forget_all () = Hashtbl.reset table
