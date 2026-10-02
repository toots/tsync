(* The runtime of spec 01 §6 on duppy. Fibers run on a domain pool, so every
   piece of shared state here is guarded by a system mutex or an atomic. *)

exception Cancelled
exception Timeout

type ctx = {
  cm : Mutex.t;
  mutable cancel : exn option;
  mutable hook : (exn -> unit) option;
  mutable children : ctx list;
}

let new_ctx () =
  { cm = Mutex.create (); cancel = None; hook = None; children = [] }

let rec cancel_ctx c exn =
  Mutex.lock c.cm;
  match c.cancel with
    | Some _ -> Mutex.unlock c.cm
    | None ->
        c.cancel <- Some exn;
        let hook = c.hook and children = c.children in
        Mutex.unlock c.cm;
        Option.iter (fun h -> h exn) hook;
        List.iter (fun ch -> cancel_ctx ch exn) children

let child_ctx parent =
  let c = new_ctx () in
  Mutex.lock parent.cm;
  let inherited = parent.cancel in
  if inherited = None then parent.children <- c :: parent.children;
  Mutex.unlock parent.cm;
  Option.iter (fun e -> c.cancel <- Some e) inherited;
  c

let detach_ctx parent c =
  Mutex.protect parent.cm (fun () ->
      parent.children <- List.filter (fun x -> x != c) parent.children)

type _ Effect.t += Current : ctx Effect.t

let root = new_ctx ()
let current () = try Effect.perform Current with Effect.Unhandled _ -> root

type fiber = ctx

let self = current
let same = ( == )

let cancelled () =
  let c = current () in
  Mutex.protect c.cm (fun () -> c.cancel)

let check () = match cancelled () with Some e -> raise e | None -> ()
let is_cancelled = function Cancelled -> true | _ -> false

let task_error =
  ref (fun exn _ ->
      Printf.eprintf "tsync: scheduler task failed: %s\n%!"
        (Printexc.to_string exn))

let scheduler : unit Duppy.scheduler =
  Duppy.create
    ~on_error:(fun exn bt -> !task_error exn bt)
    ~classify:(fun () -> `Threaded)
    ()

let start_lock = Mutex.create ()

(* Started lazily: spawning domains makes fork fail, so nothing may start them
   before a process has finished daemonizing. *)
let ensure_started () =
  if not (Duppy.started scheduler) then
    Mutex.protect start_lock (fun () ->
        if not (Duppy.started scheduler) then
          Duppy.start
            ~pool:
              (`Domains (max 2 (min 8 (Domain.recommended_domain_count ()))))
            ~max_blocking:256 scheduler)

let now = Duppy.time

let with_ctx (type r) (ctx : ctx) (fn : unit -> r) : r =
  Effect.Deep.match_with fn ()
    {
      retc = Fun.id;
      exnc =
        (fun e ->
          Printexc.raise_with_backtrace e (Printexc.get_raw_backtrace ()));
      effc =
        (fun (type a) (e : a Effect.t) ->
          match e with
            | Current ->
                Some
                  (fun (k : (a, r) Effect.Deep.continuation) ->
                    Effect.Deep.continue k ctx)
            | _ -> None);
    }

let detached_failure =
  ref (fun name exn ->
      Printf.eprintf "tsync: %s: %s\n%!" name (Printexc.to_string exn))

let spawn_in ?(name = "task") ctx fn =
  ensure_started ();
  Duppy.Task.add scheduler
    {
      priority = ();
      events = [`Delay 0.];
      handler =
        (fun _ ->
          Duppy.run (fun () ->
              with_ctx ctx (fun () ->
                  try fn () with
                    | Cancelled -> ()
                    | exn -> !detached_failure name exn));
          []);
    }

let spawn ?name fn = spawn_in ?name (child_ctx root) fn

(* [register] receives a resolver that answers whether it was the one to wake
   the fiber, since a cancellation may win the race. *)
let suspend (register : (('a, exn) result -> bool) -> unit) : 'a =
  let ctx = current () in
  check ();
  let cell = Atomic.make None in
  Duppy.suspend ~priority:() scheduler (fun resume ->
      let finish r =
        if Atomic.compare_and_set cell None (Some r) then (
          resume ();
          true)
        else false
      in
      Mutex.lock ctx.cm;
      match ctx.cancel with
        | Some e ->
            Mutex.unlock ctx.cm;
            ignore (finish (Error e))
        | None ->
            ctx.hook <- Some (fun e -> ignore (finish (Error e)));
            Mutex.unlock ctx.cm;
            register finish);
  Mutex.protect ctx.cm (fun () -> ctx.hook <- None);
  match Atomic.get cell with
    | Some (Ok v) -> v
    | Some (Error e) -> raise e
    | None -> assert false

let timer d fire =
  Duppy.Task.add scheduler
    {
      priority = ();
      events = [`Delay d];
      handler =
        (fun _ ->
          fire ();
          []);
    }

let sleep d =
  if d <= 0. then check ()
  else suspend (fun resolve -> timer d (fun () -> ignore (resolve (Ok ()))))

let yield () = suspend (fun resolve -> ignore (resolve (Ok ())))

(* Each wait is bounded so that a cancelled one never leaves its task
   registered on a descriptor for ever. *)
let wait_fd ?(timeout = infinity) ev fd =
  let deadline = now () +. timeout in
  let rec loop () =
    let left = deadline -. now () in
    if left <= 0. then raise Timeout;
    let fired =
      suspend (fun resolve ->
          Duppy.Task.add scheduler
            {
              priority = ();
              events = [ev fd; `Delay (min left 30.)];
              handler =
                (fun evs ->
                  ignore
                    (resolve
                       (Ok
                          (List.exists
                             (function `Delay _ -> false | _ -> true)
                             evs)));
                  []);
            })
    in
    if not fired then loop ()
  in
  loop ()

let wait_readable ?timeout fd = wait_fd ?timeout (fun fd -> `Read fd) fd
let wait_writable ?timeout fd = wait_fd ?timeout (fun fd -> `Write fd) fd

module Promise = struct
  type 'a state =
    | Pending of (('a, exn) result -> bool) list
    | Done of ('a, exn) result

  type 'a t = { m : Mutex.t; mutable st : 'a state }

  let create () = { m = Mutex.create (); st = Pending [] }
  let resolved v = { m = Mutex.create (); st = Done (Ok v) }

  let try_resolve_result p r =
    Mutex.lock p.m;
    match p.st with
      | Done _ ->
          Mutex.unlock p.m;
          false
      | Pending ws ->
          p.st <- Done r;
          Mutex.unlock p.m;
          List.iter (fun w -> ignore (w r)) (List.rev ws);
          true

  let try_resolve p v = try_resolve_result p (Ok v)

  let resolve p v =
    if not (try_resolve p v) then
      invalid_arg "Promise.resolve: already resolved"

  let fail p e = ignore (try_resolve_result p (Error e))

  let peek p =
    Mutex.protect p.m (fun () ->
        match p.st with Done r -> Some r | Pending _ -> None)

  let is_resolved p = peek p <> None

  let await p =
    match peek p with
      | Some (Ok v) -> v
      | Some (Error e) -> raise e
      | None ->
          suspend (fun resolve ->
              Mutex.lock p.m;
              match p.st with
                | Done r ->
                    Mutex.unlock p.m;
                    ignore (resolve r)
                | Pending ws ->
                    p.st <- Pending (resolve :: ws);
                    Mutex.unlock p.m)

  (* Not cancellable: a caller cancelled meanwhile still waits. *)
  let join p =
    if not (is_resolved p) then
      Duppy.suspend ~priority:() scheduler (fun resume ->
          let woken = Atomic.make false in
          let wake _ =
            if Atomic.compare_and_set woken false true then (
              resume ();
              true)
            else false
          in
          Mutex.lock p.m;
          match p.st with
            | Done _ ->
                Mutex.unlock p.m;
                ignore (wake ())
            | Pending ws ->
                p.st <- Pending (wake :: ws);
                Mutex.unlock p.m)
end

let async_child parent fn =
  let p = Promise.create () in
  let c = child_ctx parent in
  spawn_in c (fun () ->
      Fun.protect
        ~finally:(fun () -> detach_ctx parent c)
        (fun () ->
          match fn () with
            | v -> ignore (Promise.try_resolve p v)
            | exception e -> Promise.fail p e));
  (p, c)

let async fn = fst (async_child (current ()) fn)

(* Every child is awaited even after one fails, so none outlives the call. *)
let all fns =
  let parent = current () in
  let ps = List.map (fun fn -> async_child parent fn) fns in
  let results =
    List.map (fun (p, _) -> try Ok (Promise.await p) with e -> Error e) ps
  in
  List.map (function Ok v -> v | Error e -> raise e) results

let both f g =
  match all [(fun () -> `A (f ())); (fun () -> `B (g ()))] with
    | [`A a; `B b] -> (a, b)
    | _ -> assert false

let map_concurrently f l = all (List.map (fun x () -> f x) l)
let iter_concurrently f l = ignore (map_concurrently f l)

let first ?(detach = false) fns =
  let parent = current () in
  let winner = Promise.create () in
  let children =
    List.map
      (fun fn ->
        async_child parent (fun () ->
            match fn () with
              | v -> ignore (Promise.try_resolve winner v)
              | exception e ->
                  ignore (Promise.try_resolve_result winner (Error e))))
      fns
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (_, c) -> cancel_ctx c Cancelled) children;
      if not detach then List.iter (fun (p, _) -> Promise.join p) children)
    (fun () -> Promise.await winner)

let with_timeout ?detach d fn =
  first ?detach
    [
      fn;
      (fun () ->
        sleep d;
        raise Timeout);
    ]

let with_stall_timeout window fn =
  let last = Atomic.make (now ()) in
  let rec watchdog () =
    let left = Atomic.get last +. window -. now () in
    if left <= 0. then raise Timeout
    else (
      sleep left;
      watchdog ())
  in
  first [(fun () -> fn (fun () -> Atomic.set last (now ()))); watchdog]

module Fmutex = struct
  type t = {
    m : Mutex.t;
    mutable locked : bool;
    waiters : ((unit, exn) result -> bool) Queue.t;
  }

  let create () =
    { m = Mutex.create (); locked = false; waiters = Queue.create () }

  (* The lock is handed straight to the oldest live waiter. *)
  let unlock t =
    Mutex.lock t.m;
    let rec hand () =
      match Queue.take_opt t.waiters with
        | None -> t.locked <- false
        | Some w -> if not (w (Ok ())) then hand ()
    in
    hand ();
    Mutex.unlock t.m

  let lock t =
    Mutex.lock t.m;
    if not t.locked then (
      t.locked <- true;
      Mutex.unlock t.m)
    else (
      Mutex.unlock t.m;
      suspend (fun resolve ->
          Mutex.lock t.m;
          if not t.locked then (
            t.locked <- true;
            Mutex.unlock t.m;
            if not (resolve (Ok ())) then unlock t)
          else (
            Queue.push resolve t.waiters;
            Mutex.unlock t.m)))

  let with_lock t fn =
    lock t;
    Fun.protect ~finally:(fun () -> unlock t) fn

  let is_locked t = Mutex.protect t.m (fun () -> t.locked)
end

module Condition = struct
  type t = { m : Mutex.t; waiters : ((unit, exn) result -> bool) Queue.t }

  let create () = { m = Mutex.create (); waiters = Queue.create () }

  (* The waiter is queued before [mutex] is released, so a signal from a later
     holder of [mutex] is not lost. *)
  let wait t mutex =
    Fun.protect
      ~finally:(fun () -> Fmutex.lock mutex)
      (fun () ->
        suspend (fun resolve ->
            Mutex.protect t.m (fun () -> Queue.push resolve t.waiters);
            Fmutex.unlock mutex))

  let broadcast t =
    let ws =
      Mutex.protect t.m (fun () ->
          let l = List.of_seq (Queue.to_seq t.waiters) in
          Queue.clear t.waiters;
          l)
    in
    List.iter (fun w -> ignore (w (Ok ()))) ws

  let rec signal t =
    match Mutex.protect t.m (fun () -> Queue.take_opt t.waiters) with
      | None -> ()
      | Some w -> if not (w (Ok ())) then signal t
end

module Signal = struct
  type t = {
    m : Mutex.t;
    mutable version : int;
    mutable waiters : ((unit, exn) result -> bool) list;
  }

  let create () = { m = Mutex.create (); version = 0; waiters = [] }
  let version t = Mutex.protect t.m (fun () -> t.version)

  let wait ?since t =
    suspend (fun resolve ->
        Mutex.lock t.m;
        match since with
          | Some v when v <> t.version ->
              Mutex.unlock t.m;
              ignore (resolve (Ok ()))
          | _ ->
              t.waiters <- resolve :: t.waiters;
              Mutex.unlock t.m)

  let broadcast t =
    let ws =
      Mutex.protect t.m (fun () ->
          t.version <- t.version + 1;
          let l = t.waiters in
          t.waiters <- [];
          l)
    in
    List.iter (fun w -> ignore (w (Ok ()))) ws
end

module Semaphore = struct
  type t = {
    m : Mutex.t;
    mutable avail : int;
    max : int;
    waiters : ((unit, exn) result -> bool) Queue.t;
    name : string;
  }

  let create ?(name = "") n =
    let n = max 1 n in
    { m = Mutex.create (); avail = n; max = n; waiters = Queue.create (); name }

  let try_acquire t =
    Mutex.protect t.m (fun () ->
        if t.avail > 0 && Queue.is_empty t.waiters then (
          t.avail <- t.avail - 1;
          true)
        else false)

  let rec release t =
    Mutex.lock t.m;
    match Queue.take_opt t.waiters with
      | None ->
          t.avail <- t.avail + 1;
          Mutex.unlock t.m
      | Some w ->
          Mutex.unlock t.m;
          if not (w (Ok ())) then release t

  let acquire t =
    if not (try_acquire t) then
      suspend (fun resolve ->
          Mutex.lock t.m;
          if t.avail > 0 && Queue.is_empty t.waiters then (
            t.avail <- t.avail - 1;
            Mutex.unlock t.m;
            if not (resolve (Ok ())) then release t)
          else (
            Queue.push resolve t.waiters;
            Mutex.unlock t.m))

  let with_slot t fn =
    acquire t;
    Fun.protect ~finally:(fun () -> release t) fn

  let stats t =
    Mutex.protect t.m (fun () ->
        (t.name, t.max - t.avail, Queue.length t.waiters, t.max))
end

(* Workers pull items, so nothing is allocated per element up front; results
   keep input order. *)
let map_bounded ~width f items =
  let arr = Array.of_list items in
  let n = Array.length arr in
  let res = Array.make n None in
  let next = Atomic.make 0 in
  let rec worker () =
    let i = Atomic.fetch_and_add next 1 in
    if i < n then (
      res.(i) <- Some (f arr.(i));
      worker ())
  in
  ignore (all (List.init (max 1 (min width n)) (fun _ -> worker)));
  Array.to_list (Array.map Option.get res)

let iter_bounded ~width f items = ignore (map_bounded ~width f items)

let each ~width (next : unit -> 'a option) f =
  let m = Mutex.create () in
  let rec worker () =
    match Mutex.protect m next with
      | None -> ()
      | Some x ->
          f x;
          worker ()
  in
  ignore (all (List.init (max 1 width) (fun _ -> worker)))

(* Blocks the calling system thread until [fn], run as a fiber, completes: the
   entry point of the main thread and of foreign threads (FUSE, JNI). *)
let run_sync fn =
  ensure_started ();
  let m = Mutex.create () and c = Stdlib.Condition.create () in
  let result = ref None in
  spawn_in (child_ctx root) (fun () ->
      let r =
        try Ok (fn ()) with e -> Error (e, Printexc.get_raw_backtrace ())
      in
      Mutex.protect m (fun () ->
          result := Some r;
          Stdlib.Condition.broadcast c));
  Mutex.lock m;
  while !result = None do
    Stdlib.Condition.wait c m
  done;
  Mutex.unlock m;
  match Option.get !result with
    | Ok v -> v
    | Error (e, bt) -> Printexc.raise_with_backtrace e bt
