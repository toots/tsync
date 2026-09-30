open Tsync_core

let burst_seconds = 2.
let stall_timeout = 60.
let window_safety = 0.5
let small_body = 64 * 1024
let request_overhead = 1024

module Budget = struct
  type t = {
    rate : float;
    mutable tokens : float;
    mutable filled_at : float;
    mutable in_flight : int;
  }

  let burst t = t.rate *. burst_seconds
  let window t = t.rate *. stall_timeout *. window_safety

  let create ~rate ~now =
    let rate = Float.max 1. rate in
    { rate; tokens = rate *. burst_seconds; filled_at = now; in_flight = 0 }

  let refill t ~now =
    if now > t.filled_at then (
      t.tokens <-
        Float.min (burst t) (t.tokens +. (t.rate *. (now -. t.filled_at)));
      t.filled_at <- now)

  (* A body larger than the bucket needs only a full one; the excess is debt. *)
  let asks t b = Float.min (float_of_int b) (burst t)

  let window_admits t b =
    t.in_flight = 0 || float_of_int (t.in_flight + b) <= window t

  let admits t ~now b =
    refill t ~now;
    t.tokens >= asks t b && window_admits t b

  let take t ~now b =
    refill t ~now;
    t.tokens <- t.tokens -. float_of_int b;
    t.in_flight <- t.in_flight + b

  let release t b = t.in_flight <- max 0 (t.in_flight - b)

  let wait_for t ~now b =
    refill t ~now;
    if not (window_admits t b) then infinity
    else Float.max 0. ((asks t b -. t.tokens) /. t.rate)
end

type waiter = { bytes : int; wake : (unit, exn) result Rt.Promise.t }

type gate = {
  m : Mutex.t;
  budget : Budget.t;
  line : waiter Queue.t;
  mutable overtaken : int;
  mutable armed : bool;
}

type t = Open | Governed of gate
type ticket = { taken : int }

let none = Open
let links : (string, t) Hashtbl.t = Hashtbl.create 4
let links_m = Mutex.create ()

let link name ~enabled ~max_rate =
  Mutex.protect links_m (fun () ->
      match Hashtbl.find_opt links name with
        | Some t -> t
        | None ->
            let t =
              match (enabled, max_rate) with
                | true, Some rate ->
                    Governed
                      {
                        m = Mutex.create ();
                        budget =
                          Budget.create ~rate:(float_of_int rate)
                            ~now:(Rt.now ());
                        line = Queue.create ();
                        overtaken = 0;
                        armed = false;
                      }
                | _ -> Open
            in
            Hashtbl.replace links name t;
            t)

(* Called under [g.m]. *)
let rec pump g =
  match Queue.peek_opt g.line with
    | Some w when Budget.admits g.budget ~now:(Rt.now ()) w.bytes ->
        ignore (Queue.pop g.line);
        g.overtaken <- 0;
        if Rt.Promise.try_resolve w.wake (Ok ()) then
          Budget.take g.budget ~now:(Rt.now ()) w.bytes;
        pump g
    | _ -> ()

(* One timer at most; a head blocked by the window waits for a completion. *)
and arm g =
  if not g.armed then (
    match Queue.peek_opt g.line with
      | Some w ->
          let delay = Budget.wait_for g.budget ~now:(Rt.now ()) w.bytes in
          if delay < infinity then (
            g.armed <- true;
            Rt.timer (Float.max 0.001 delay) (fun () ->
                Mutex.protect g.m (fun () ->
                    g.armed <- false;
                    pump g;
                    arm g)))
      | None -> ())

(* §4.3: a small body may pass the head, by at most the head's size in all. *)
let room g b =
  (match Queue.peek_opt g.line with
    | None -> true
    | Some head -> b <= small_body && g.overtaken + b <= head.bytes)
  && Budget.admits g.budget ~now:(Rt.now ()) b

let take_now g b =
  if not (Queue.is_empty g.line) then g.overtaken <- g.overtaken + b;
  Budget.take g.budget ~now:(Rt.now ()) b

let acquire t bytes =
  let b = bytes + request_overhead in
  match t with
    | Open -> { taken = 0 }
    | Governed g -> (
        let waiter =
          Mutex.protect g.m (fun () ->
              if room g b then (
                take_now g b;
                None)
              else (
                let w = { bytes = b; wake = Rt.Promise.create () } in
                Queue.push w g.line;
                arm g;
                Some w))
        in
        match waiter with
          | None -> { taken = b }
          | Some w ->
              let unregister =
                Stop.on_request (fun () ->
                    ignore (Rt.Promise.try_resolve w.wake (Error Stop.Stopping)))
              in
              Fun.protect ~finally:unregister (fun () ->
                  match Rt.Promise.await w.wake with
                    | Ok () -> { taken = b }
                    | Error e -> raise e
                    | exception e ->
                        (* A waiter cancelled while in line leaves it having
                           taken nothing. *)
                        Mutex.protect g.m (fun () ->
                            if not (Rt.Promise.try_resolve w.wake (Error e))
                            then Budget.release g.budget b;
                            let kept = Queue.create () in
                            Queue.iter
                              (fun x -> if x != w then Queue.push x kept)
                              g.line;
                            Queue.clear g.line;
                            Queue.transfer kept g.line;
                            pump g;
                            arm g);
                        raise e))

let try_acquire t bytes =
  let b = bytes + request_overhead in
  match t with
    | Open -> Some { taken = 0 }
    | Governed g ->
        Mutex.protect g.m (fun () ->
            if room g b then (
              take_now g b;
              Some { taken = b })
            else None)

let release t ticket =
  match t with
    | Open -> ()
    | Governed g ->
        Mutex.protect g.m (fun () ->
            Budget.release g.budget ticket.taken;
            pump g;
            arm g)

let completed t ticket = release t ticket
let abandoned t ticket = release t ticket

let waiting = function
  | Open -> 0
  | Governed g -> Mutex.protect g.m (fun () -> Queue.length g.line)

let admitted t (mode : Store.mode) bytes f =
  let ticket =
    match mode with
      | Wait -> acquire t bytes
      | Best_effort -> (
          match try_acquire t bytes with
            | Some ticket -> ticket
            | None -> raise Rt.Cancelled)
  in
  match f () with
    | v ->
        completed t ticket;
        v
    | exception e ->
        abandoned t ticket;
        raise e
