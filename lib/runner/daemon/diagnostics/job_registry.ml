(* What the daemon knows about commands running beside it.

   Advisory throughout: a job that never reports is simply absent from a status
   listing, and a row that outlives its process is wrong in a way nobody acts
   on. Nothing here is allowed to affect a running command. *)

type entry = {
  pid : int;
  started : float;
  interval : float;
  finished : bool;
  seen : float;
  report : Yojson.Safe.t;
}

(* A job silent for several of its own report intervals has stopped saying
   anything, whatever its pid says. The floor covers one reporting so often that
   two missed sends would retire it. *)
let stale_after e = Float.max 45. (4. *. e.interval)

(* A finished job stays visible this long, so a command that ran between two
   status calls is not invisible in both. *)
let keep_done = 300.

(* Keyed by the job rather than the process: a pid runs one command at a time,
   and a second report from the same pid replaces the first. *)
let table : (int, entry) Hashtbl.t = Hashtbl.create 4

(* A pid reused between two reports keeps a stale row until silence retires it,
   which is why liveness alone is not the test. *)
let alive = Fs_util.pid_alive

let expired now e =
  if e.finished then now -. e.seen > keep_done
  else now -. e.seen > stale_after e || not (alive e.pid)

(* On write as well as on read: how many rows the table holds is decided by how
   many commands have run, which is not something this code chose. *)
let prune () =
  let now = Unix.gettimeofday () in
  Hashtbl.iter
    (fun pid e -> if expired now e then Hashtbl.remove table pid)
    (Hashtbl.copy table)

let record ~pid ~started ~interval ~finished report =
  if pid > 0 then begin
    prune ();
    Hashtbl.replace table pid
      { pid; started; interval; finished; seen = Unix.gettimeofday (); report }
  end

(* Oldest first, so a listing reads in the order the jobs started. *)
let live () =
  prune ();
  Hashtbl.fold (fun _ e acc -> e :: acc) table []
  |> List.sort (fun a b -> compare a.started b.started)
  |> List.map (fun e -> e.report)
