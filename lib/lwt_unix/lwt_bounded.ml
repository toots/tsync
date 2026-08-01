exception Busy

type t = {
  limit : int;
  max_waiting : int option;
  mutable held : int;
  mutable waiting : int;
  waiters : unit Lwt.u Queue.t;
}

let create ?max_waiting ~max () =
  {
    limit = (if max < 1 then 1 else max);
    max_waiting;
    held = 0;
    waiting = 0;
    waiters = Queue.create ();
  }

let in_flight t = t.held
let waiting t = t.waiting
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

(* One fan-out gets its own bound: these limit a single caller-sized list
   against the resources that list acquires, and a process-wide budget would
   make unrelated work queue behind a large transfer. The queue is left
   unbounded — every element is already in hand, so refusing one would only
   force the caller to hold it instead. *)
let map_with t f xs = Lwt_list.map_p (fun x -> use t (fun () -> f x)) xs
let iter_with t f xs = Lwt_list.iter_p (fun x -> use t (fun () -> f x)) xs
let filter_map_with t f xs = Lwt.map (List.filter_map Fun.id) (map_with t f xs)
let map ~max f xs = map_with (create ~max ()) f xs
let iter ~max f xs = iter_with (create ~max ()) f xs
let filter_map ~max f xs = filter_map_with (create ~max ()) f xs
