exception Busy

type t = {
  limit : int;
  max_waiting : int option;
  mutable held : int;
  mutable waiting : int;
  waiters : unit Lwt.u Queue.t;
}

(* A pool stands for a resource, so a named one is registered for the life of
   the process and reported on: [waiting] above zero is the difference between
   work that is slow and work that is queued behind a bound, and nothing could
   tell those apart from outside.

   Name only a pool created once at startup: nothing is ever pruned, so naming
   one built per request would grow this with the request count. *)
let named : (string * t) list ref = ref []

let create ?max_waiting ?name ~max () =
  let t =
    {
      limit = (if max < 1 then 1 else max);
      max_waiting;
      held = 0;
      waiting = 0;
      waiters = Queue.create ();
    }
  in
  (match name with None -> () | Some n -> named := !named @ [(n, t)]);
  t

let in_flight t = t.held
let waiting t = t.waiting
let width t = t.limit

(* Creation order, so one run's report can be read against another's. *)
let totals () =
  List.fold_left
    (fun acc (name, t) ->
      if List.exists (fun (n, _, _, _) -> n = name) acc then
        List.map
          (fun (n, f, w, l) ->
            if n = name then (n, f + t.held, w + t.waiting, l + t.limit)
            else (n, f, w, l))
          acc
      else acc @ [(name, t.held, t.waiting, t.limit)])
    [] !named

let full t = match t.max_waiting with Some n -> t.waiting >= n | None -> false

let acquire t =
  if t.held < t.limit then (
    t.held <- t.held + 1;
    Lwt.return_true)
  else if full t then Lwt.return_false
  else begin
    let waited, wake = Lwt.wait () in
    t.waiting <- t.waiting + 1;
    Queue.add wake t.waiters;
    Lwt.map (fun () -> true) waited
  end

(* The slot goes straight to the next waiter rather than being released and
   competed for again, so a queue cannot be starved by an arrival that happens
   to ask at the right moment. *)
let release t =
  match Queue.take_opt t.waiters with
    | Some wake ->
        t.waiting <- t.waiting - 1;
        Lwt.wakeup_later wake ()
    | None -> t.held <- t.held - 1

let use_or t ~busy f =
  Lwt.bind (acquire t) (fun ok ->
      if not ok then busy ()
      else
        Lwt.finalize f (fun () ->
            release t;
            Lwt.return_unit))

let use t f = use_or t ~busy:(fun () -> Lwt.fail Busy) f

(* Own bound per fan-out: a process-wide budget would make unrelated work queue
   behind a large transfer. The queue is unbounded — every element is already in
   hand, so refusing one only forces the caller to hold it. *)
let map_with t f xs = Lwt_list.map_p (fun x -> use t (fun () -> f x)) xs
let iter_with t f xs = Lwt_list.iter_p (fun x -> use t (fun () -> f x)) xs
let filter_map_with t f xs = Lwt.map (List.filter_map Fun.id) (map_with t f xs)

(* Taking a job and moving the source on happens between binds, so no worker
   sees it part-way through another's turn.

   A worker stops at the first failure rather than draining what is left, so a
   cancelled upload does not go on reading a file it has already given up on. *)
let each ~width next =
  let stop = ref None in
  let rec worker () =
    if Option.is_some !stop then Lwt.return_unit
    else (
      match next () with
        | None -> Lwt.return_unit
        | Some job ->
            Lwt.bind
              (Lwt.catch
                 (fun () -> Lwt.map (fun () -> None) (job ()))
                 (fun exn -> Lwt.return_some exn))
              (function
                | None -> worker ()
                | Some exn ->
                    if Option.is_none !stop then stop := Some exn;
                    Lwt.return_unit))
  in
  Lwt.bind
    (Lwt.join (List.init (if width < 1 then 1 else width) (fun _ -> worker ())))
    (fun () ->
      match !stop with Some exn -> Lwt.fail exn | None -> Lwt.return_unit)
