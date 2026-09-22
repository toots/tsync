let clock = ref 0.

(* Each sleep with its promise as well as its waker: a sleep [pick] cancelled
   is no longer sleeping, and waking it would be an error rather than a no-op. *)
let sleepers : (float * unit Lwt.t * unit Lwt.u) list ref = ref []

let now () = !clock

let sleep seconds =
  if seconds <= 0. then Lwt.return_unit
  else begin
    let waited, wake = Lwt.task () in
    sleepers := (!clock +. seconds, waited, wake) :: !sleepers;
    waited
  end

let advance seconds =
  clock := !clock +. seconds;
  let due, later =
    List.partition (fun (deadline, _, _) -> deadline <= !clock) !sleepers
  in
  sleepers := List.filter (fun (_, waited, _) -> Lwt.is_sleeping waited) later;
  List.iter
    (fun (_, waited, wake) ->
      if Lwt.is_sleeping waited then Lwt.wakeup_later wake ())
    (List.sort (fun (a, _, _) (b, _, _) -> compare a b) due)

let pending () =
  List.length (List.filter (fun (_, waited, _) -> Lwt.is_sleeping waited) !sleepers)

let reset () =
  clock := 0.;
  sleepers := []

let with_timeout seconds f =
  Lwt.pick
    [f (); Lwt.bind (sleep seconds) (fun () -> Lwt.fail Lwt_unix.Timeout)]

(* As {!Io_lwt.Clock.with_stall_timeout}, reading this clock: the watcher is
   rearmed to the moment the silence would be too long. *)
let with_stall_timeout seconds f =
  let heard = ref (now ()) in
  let alive () = heard := now () in
  let rec watch () =
    let left = !heard +. seconds -. now () in
    if left <= 0. then Lwt.fail Lwt_unix.Timeout
    else Lwt.bind (sleep left) watch
  in
  Lwt.pick [f alive; watch ()]

let pick = Lwt.pick
let is_timeout exn = exn = Lwt_unix.Timeout
let is_cancelled exn = exn = Lwt.Canceled
