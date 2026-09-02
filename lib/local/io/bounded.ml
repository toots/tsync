exception Busy

module type S = Bounded_intf.S

module Make (Io : Io.S) = struct
  open Io_syntax.Make (Io)

  type t = {
    limit : int;
    max_waiting : int option;
    mutable held : int;
    mutable waiting : int;
    waiters : unit Io.u Queue.t;
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

  let shared_pools : (string, t) Hashtbl.t = Hashtbl.create 8

  let shared ~key ~name ~max () =
    match Hashtbl.find_opt shared_pools key with
      | Some t -> t
      | None ->
          let t = create ~name ~max () in
          Hashtbl.replace shared_pools key t;
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

  let full t =
    match t.max_waiting with Some n -> t.waiting >= n | None -> false

  let acquire t =
    if t.held < t.limit then (
      t.held <- t.held + 1;
      Io.return true)
    else if full t then Io.return false
    else begin
      let waited, wake = Io.wait () in
      t.waiting <- t.waiting + 1;
      Queue.add wake t.waiters;
      let+ () = waited in
      true
    end

  (* The slot goes straight to the next waiter rather than being released and
     competed for again, so a queue cannot be starved by an arrival that happens
     to ask at the right moment. *)
  let release t =
    match Queue.take_opt t.waiters with
      | Some wake ->
          t.waiting <- t.waiting - 1;
          Io.wakeup_later wake ()
      | None -> t.held <- t.held - 1

  let use_or t ~busy f =
    let* ok = acquire t in
    if not ok then busy ()
    else
      Io.finalize f (fun () ->
          release t;
          Io.return ())

  let use t f = use_or t ~busy:(fun () -> Io.fail Busy) f

  (* Own bound per fan-out: a process-wide budget would make unrelated work queue
     behind a large transfer. The queue is unbounded — every element is already
     in hand, so refusing one only forces the caller to hold it. *)
  let map_with t f xs = Io.map_p (fun x -> use t (fun () -> f x)) xs
  let iter_with t f xs = Io.iter_p (fun x -> use t (fun () -> f x)) xs
  let filter_map_with t f xs = Io.map (List.filter_map Fun.id) (map_with t f xs)

  (* Taking a job and moving the source on happens between binds, so no worker
     sees it part-way through another's turn.

     A worker stops at the first failure rather than draining what is left, so a
     cancelled upload does not go on reading a file it has already given up on. *)
  let each ~width next =
    let stop = ref None in
    let rec worker () =
      if Option.is_some !stop then Io.return ()
      else (
        match next () with
          | None -> Io.return ()
          | Some job -> (
              let* failed =
                Io.catch
                  (fun () ->
                    let+ () = job () in
                    None)
                  (fun exn -> Io.return (Some exn))
              in
              match failed with
                | None -> worker ()
                | Some exn ->
                    if Option.is_none !stop then stop := Some exn;
                    Io.return ()))
    in
    let* () =
      Io.join (List.init (if width < 1 then 1 else width) (fun _ -> worker ()))
    in
    match !stop with Some exn -> Io.fail exn | None -> Io.return ()
end
