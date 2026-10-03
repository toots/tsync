let backoff n = min 300. (0.5 *. (2. ** float_of_int (min 10 (max 0 (n - 1)))))
let rearm_interval = 60.
let settle_timeout = 60.

let valid_id s =
  s <> ""
  && s.[0] >= '0'
  && s.[0] <= '9'
  && String.for_all
       (fun c ->
         (c >= '0' && c <= '9')
         || (c >= 'a' && c <= 'z')
         || (c >= 'A' && c <= 'Z')
         || c = '-')
       s

let seq = Atomic.make 0

let submission_id () =
  let us = Int64.of_float (Unix.gettimeofday () *. 1e6) in
  Printf.sprintf "%020Ld-%08d-%d" us
    (Atomic.fetch_and_add seq 1 mod 100000000)
    (Unix.getpid ())

let submitter_pid id =
  match String.split_on_char '-' id with
    | [_; _; pid] -> int_of_string_opt pid
    | _ -> None

module Records = struct
  type t = { dir : string; locks : (string, Mutex.t) Hashtbl.t; m : Mutex.t }

  let open_ dir =
    Fs.mkdir_p dir;
    { dir; locks = Hashtbl.create 16; m = Mutex.create () }

  let dir t = t.dir
  let path t id = Filename.concat t.dir id

  let record_lock t id =
    Mutex.protect t.m (fun () ->
        match Hashtbl.find_opt t.locks id with
          | Some l -> l
          | None ->
              let l = Mutex.create () in
              Hashtbl.replace t.locks id l;
              l)

  let rec create ?(mint = submission_id) t body =
    let id = mint () in
    match Fs.create_if_absent (path t id) body with
      | `Created -> id
      | `Exists -> create ~mint t body

  let rec create_held ?(mint = submission_id) t body =
    let id = mint () in
    match Fs.create_if_absent_locked (path t id) body with
      | `Created fd -> (id, fd)
      | `Exists -> create_held ~mint t body

  let read t id =
    match Fs.read_file_opt (path t id) with Some b -> `Body b | None -> `Gone

  (* A record completed meanwhile is never resurrected. *)
  let update t id f =
    Mutex.protect (record_lock t id) (fun () ->
        match read t id with
          | `Gone -> ()
          | `Body b -> Fs.durable_replace (path t id) (f b))

  let replace t id body =
    Mutex.protect (record_lock t id) (fun () ->
        Fs.durable_replace (path t id) body)

  let complete t id =
    Mutex.protect (record_lock t id) (fun () -> ignore (Fs.release (path t id)));
    Mutex.protect t.m (fun () -> Hashtbl.remove t.locks id)

  let set_aside_name t id =
    let rec pick n =
      let name =
        if n = 1 then id ^ ".bad" else Printf.sprintf "%s.bad.%d" id n
      in
      if Fs.exists (path t name) then pick (n + 1) else name
    in
    pick 1

  let set_aside t id =
    let name = set_aside_name t id in
    Fs.rename (path t id) (path t name);
    Fs.fsync_dir t.dir;
    Log.warn "%s: record %s does not decode; set aside as %s" t.dir id name

  let set_aside_records t =
    List.filter
      (fun n ->
        String.contains n '.'
        && (not (Names.is_temp_name n))
        && String.length n > 4)
      (Fs.readdir t.dir)
    |> List.filter (fun n ->
        match String.index_opt n '.' with
          | Some i -> valid_id (String.sub n 0 i)
          | None -> false)

  let list t = List.filter valid_id (Fs.readdir t.dir)

  (* One atomic rename then a directory fsync: exactly one name exists at every
     instant. *)
  let rekey t id id' =
    Fs.rename_noreplace (path t id) (path t id');
    Fs.fsync_dir t.dir

  (* A submitter holds its record's lock while the record must not run. *)
  let is_held t id =
    match
      Fs.opt (fun () -> Unix.openfile (path t id) [O_RDONLY; O_CLOEXEC] 0)
    with
      | None -> false
      | Some fd ->
          Fs.with_fd fd (fun fd ->
              if Fs.flock ~block:false fd then (
                Fs.funlock fd;
                false)
              else true)

  (* Pitfall C-7.10: the descriptor is the caller's only once locked. *)
  let hold t id =
    let fd = Fs.openfile (path t id) [O_RDONLY] in
    match Fs.flock ~block:true fd with
      | true -> fd
      | false ->
          Fs.close fd;
          Fail.raise_ Fail.Local "cannot hold %s" id
      | exception e ->
          Fs.close fd;
          raise e
end

type 'job kind = {
  decode : string -> 'job option;
  encode : 'job -> string;
  key : 'job -> string option;
  note : 'job -> Fail.t -> 'job;
  accepts : 'job -> bool;
}

type failure_note = { attempts : int; last : Fail.t }

type slot = {
  mutable running : string option;
  mutable pending : string option;
  mutable cancel : bool Atomic.t;
  mutable not_before : float;
}

type 'job t = {
  name : string;
  log : Records.t;
  kind : 'job kind;
  ordered : bool;
  workers : int;
  m : Mutex.t;
  wake : Rt.Signal.t;
  mutable order : string list;
  mutable loaded : string list;
  slots : (string, slot) Hashtbl.t;
  mutable ready : string list;
  mutable parked : (string * failure_note) list;
  failures : (string, failure_note) Hashtbl.t;
  mutable paused : bool;
  mutable started : bool;
  mutable active : int;
  mutable outcome_count : int;
  mutable last_failure_at : float;
  mutable run : string -> 'job -> cancel:bool Atomic.t -> unit;
  mutable completed : int;
}

let create ?(workers = 1) ~name ~ordered kind log =
  {
    name;
    log;
    kind;
    ordered;
    workers = (if ordered then 1 else max 1 workers);
    m = Mutex.create ();
    wake = Rt.Signal.create ();
    order = [];
    loaded = [];
    slots = Hashtbl.create 16;
    ready = [];
    parked = [];
    failures = Hashtbl.create 16;
    paused = false;
    started = false;
    active = 0;
    outcome_count = 0;
    last_failure_at = neg_infinity;
    run = (fun _ _ ~cancel:_ -> ());
    completed = 0;
  }

let slot_key t id job =
  if t.ordered then id else Option.value ~default:id (t.kind.key job)

let get_slot t k =
  match Hashtbl.find_opt t.slots k with
    | Some s -> s
    | None ->
        let s =
          {
            running = None;
            pending = None;
            cancel = Atomic.make false;
            not_before = 0.;
          }
        in
        Hashtbl.replace t.slots k s;
        s

(* Must hold [t.m]. *)
let take t id job =
  if not (List.mem id t.loaded) then (
    t.loaded <- id :: t.loaded;
    if t.ordered then t.order <- List.merge compare t.order [id]
    else (
      let k = slot_key t id job in
      let s = get_slot t k in
      match s.running with
        | Some _ ->
            Atomic.set s.cancel true;
            Option.iter
              (fun old ->
                Records.complete t.log old;
                t.loaded <- List.filter (( <> ) old) t.loaded)
              s.pending;
            s.pending <- Some id
        | None ->
            (match s.pending with
              | Some old when old < id ->
                  Records.complete t.log old;
                  t.loaded <- List.filter (( <> ) old) t.loaded;
                  s.pending <- Some id
              | Some _ ->
                  Records.complete t.log id;
                  t.loaded <- List.filter (( <> ) id) t.loaded
              | None -> s.pending <- Some id);
            if not (List.mem k t.ready) then t.ready <- t.ready @ [k]))

(* durable-queue R6: a record that cannot be read stays in place for a later
   attempt. *)
let decode_record t id =
  match Records.read t.log id with
    | `Gone -> `Gone
    | `Body b -> (
        match t.kind.decode b with
          | Some j -> `Job j
          | None ->
              Records.set_aside t.log id;
              `Gone)
    | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
    | exception e -> `Unreadable (Fail.classify e)

let adopt t id =
  match decode_record t id with
    | `Job job when t.kind.accepts job ->
        Mutex.protect t.m (fun () -> take t id job);
        Rt.Signal.broadcast t.wake
    | `Unreadable fl ->
        Log.warn "%s: cannot read %s, left for a later rescan: %s" t.name id
          (Fail.to_string fl)
    | _ -> ()

let post ?mint t job =
  let id = Records.create ?mint t.log (t.kind.encode job) in
  Mutex.protect t.m (fun () -> take t id job);
  Rt.Signal.broadcast t.wake;
  id

let is_parked t id = List.mem_assoc id t.parked

(* Records a submitter still holds are skipped until a later rescan, and a
   submitter's records are adopted in id order. *)
let rescan ?(rekey : (string -> string option) option) t =
  let held_pids = Hashtbl.create 4 in
  List.iter
    (fun id ->
      let loaded =
        Mutex.protect t.m (fun () -> List.mem id t.loaded || is_parked t id)
      in
      if not loaded then (
        let pid = submitter_pid id in
        let blocked =
          match pid with Some p -> Hashtbl.mem held_pids p | None -> false
        in
        try
          if blocked || Records.is_held t.log id then
            Option.iter (fun p -> Hashtbl.replace held_pids p ()) pid
          else (
            let id =
              match Option.bind rekey (fun f -> f id) with
                | Some id' ->
                    Records.rekey t.log id id';
                    id'
                | None -> id
            in
            adopt t id)
        with
          | (Stop.Stopping | Rt.Cancelled) as e -> raise e
          | e ->
              Log.warn "%s: cannot read %s, left for a later rescan: %s" t.name
                id (Printexc.to_string e)))
    (Records.list t.log)

let rearm t =
  let ps =
    Mutex.protect t.m (fun () ->
        let l = t.parked in
        t.parked <- [];
        l)
  in
  List.iter (fun (id, _) -> adopt t id) ps;
  List.length ps

let pause t = Mutex.protect t.m (fun () -> t.paused <- true)

let resume t =
  Mutex.protect t.m (fun () -> t.paused <- false);
  Rt.Signal.broadcast t.wake

let is_paused t = Mutex.protect t.m (fun () -> t.paused)

let count_failure t id fl =
  Mutex.protect t.m (fun () ->
      let n =
        match Hashtbl.find_opt t.failures id with
          | Some f -> f.attempts
          | None -> 0
      in
      let note = { attempts = n + 1; last = fl } in
      Hashtbl.replace t.failures id note;
      t.last_failure_at <- Rt.now ();
      note)

let note_failure t id fl =
  let note = count_failure t id fl in
  (try
     Records.update t.log id (fun b ->
         match t.kind.decode b with
           | Some j -> t.kind.encode (t.kind.note j fl)
           | None -> b)
   with e ->
     Log.warn "%s: cannot note the failure of %s: %s" t.name id
       (Printexc.to_string e));
  note

(* Holding [t.m]. *)
let forget_locked t id =
  t.loaded <- List.filter (( <> ) id) t.loaded;
  Hashtbl.remove t.failures id

let forget t id = Mutex.protect t.m (fun () -> forget_locked t id)

let done_ t id =
  Records.complete t.log id;
  Mutex.protect t.m (fun () ->
      t.completed <- t.completed + 1;
      t.outcome_count <- t.outcome_count + 1);
  forget t id

let failed t id e =
  let fl = Fail.classify e in
  let note = note_failure t id fl in
  Mutex.protect t.m (fun () -> t.outcome_count <- t.outcome_count + 1);
  let retryable =
    Fail.retryable fl.kind && not (t.ordered && fl.kind = Unexplained)
  in
  let retryable = retryable || ((not t.ordered) && fl.kind = Unexplained) in
  if retryable then (
    Log.info "%s: %s failed (%s), retrying" t.name id (Fail.to_string fl);
    `Retry (backoff note.attempts))
  else (
    Log.warn "%s: %s parked: %s" t.name id (Fail.to_string fl);
    Mutex.protect t.m (fun () ->
        t.loaded <- List.filter (( <> ) id) t.loaded;
        t.parked <- (id, note) :: List.remove_assoc id t.parked);
    `Parked)

(* One job, to one outcome (durable-queue §4.6). *)
let run_one t id job cancel =
  match t.run id job ~cancel with
    | () | (exception Rt.Cancelled) -> (
        match done_ t id with
          | () -> `Done
          | exception Stop.Stopping ->
              forget t id;
              `Stopping
          | exception e -> failed t id e)
    | exception Stop.Stopping ->
        forget t id;
        `Stopping
    | exception e -> failed t id e

let unreadable t id fl =
  let note = count_failure t id fl in
  Log.warn "%s: cannot read %s, retrying: %s" t.name id (Fail.to_string fl);
  backoff note.attempts

let wait_work ?since t =
  if Stop.requested () then raise Stop.Stopping;
  Rt.first
    [
      (fun () -> Rt.Signal.wait ?since t.wake);
      (fun () ->
        Stop.wait ();
        raise Stop.Stopping);
    ]

let ordered_worker t =
  let rec loop () =
    (* §4.8: under a stop, no new job is taken. *)
    Stop.check ();
    let since = Rt.Signal.version t.wake in
    let head =
      Mutex.protect t.m (fun () ->
          if t.paused then None
          else (match t.order with id :: _ -> Some id | [] -> None))
    in
    match head with
      | None ->
          wait_work ~since t;
          loop ()
      | Some id -> (
          let drop () =
            Mutex.protect t.m (fun () ->
                t.order <- List.filter (( <> ) id) t.order)
          in
          match decode_record t id with
            | `Gone ->
                drop ();
                forget t id;
                loop ()
            | `Unreadable fl ->
                Stop.sleep (unreadable t id fl);
                loop ()
            | `Job job -> (
                Mutex.protect t.m (fun () -> t.active <- 1);
                let r = run_one t id job (Atomic.make false) in
                Mutex.protect t.m (fun () -> t.active <- 0);
                match r with
                  | `Done | `Parked ->
                      drop ();
                      loop ()
                  | `Stopping -> ()
                  | `Retry d ->
                      Stop.sleep d;
                      loop ()))
  in
  try loop () with Stop.Stopping -> ()

let keyed_worker t =
  let next () =
    Mutex.protect t.m (fun () ->
        if t.paused then None
        else (
          let now = Rt.now () in
          let rec pick skipped = function
            | [] -> None
            | k :: rest -> (
                match Hashtbl.find_opt t.slots k with
                  | Some ({ running = None; pending = Some id; _ } as s)
                    when s.not_before <= now ->
                      t.ready <- List.rev_append skipped rest;
                      s.running <- Some id;
                      s.pending <- None;
                      s.cancel <- Atomic.make false;
                      t.active <- t.active + 1;
                      Some (k, s, id)
                  | Some { pending = Some _; _ } -> pick (k :: skipped) rest
                  | _ -> pick skipped rest)
          in
          pick [] t.ready))
  in
  let finish k s ~requeue =
    Mutex.protect t.m (fun () ->
        s.running <- None;
        t.active <- t.active - 1;
        if s.pending <> None && not (List.mem k t.ready) then
          t.ready <- t.ready @ [k];
        if s.pending = None && s.running = None then Hashtbl.remove t.slots k;
        ignore requeue);
    Rt.Signal.broadcast t.wake
  in
  let rec loop () =
    Stop.check ();
    let since = Rt.Signal.version t.wake in
    match next () with
      | None ->
          let delay =
            Mutex.protect t.m (fun () ->
                Hashtbl.fold
                  (fun _ s acc ->
                    if s.pending <> None && s.running = None then
                      min acc (s.not_before -. Rt.now ())
                    else acc)
                  t.slots infinity)
          in
          (* A record ready while paused waits for the resume: nothing else
             would end the wait, and looping at once spins a core. *)
          if delay < infinity && delay > 0. then
            ignore
              (Rt.first
                 [(fun () -> Stop.sleep delay); (fun () -> wait_work ~since t)])
          else wait_work ~since t;
          loop ()
      | Some (k, s, id) ->
          (* Pitfall C-7.10: the slot is finished once, on every path; a record
             that fails to decode is retried like an unreadable one. *)
          let requeue = ref false and stopping = ref false in
          Fun.protect
            ~finally:(fun () -> finish k s ~requeue:!requeue)
            (fun () ->
              let outcome =
                match decode_record t id with
                  | `Gone ->
                      forget t id;
                      `Done
                  | `Unreadable fl -> `Retry (unreadable t id fl)
                  | `Job job -> run_one t id job s.cancel
                  | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
                  | exception e -> `Retry (unreadable t id (Fail.classify e))
              in
              match outcome with
                | `Done | `Parked -> ()
                | `Stopping -> stopping := true
                | `Retry d ->
                    requeue := true;
                    let superseded =
                      Mutex.protect t.m (fun () ->
                          s.not_before <- Rt.now () +. d;
                          if s.pending = None then (
                            s.pending <- Some id;
                            false)
                          else (
                            forget_locked t id;
                            true))
                    in
                    (* A newer job replaced it; a record left behind is
                       adopted again by the next rescan. *)
                    if superseded then (
                      try Records.complete t.log id
                      with e when not (Rt.is_cancelled e) ->
                        Log.warn "%s: cannot complete %s: %s" t.name id
                          (Printexc.to_string e)));
          if not !stopping then loop ()
  in
  try loop () with Stop.Stopping -> ()

let start ?(paused = false) ?rekey t run =
  t.run <- run;
  t.paused <- paused;
  rescan ?rekey t;
  if not t.started then (
    t.started <- true;
    for _ = 1 to t.workers do
      Rt.spawn ~name:t.name (fun () ->
          if t.ordered then ordered_worker t else keyed_worker t)
    done)

let pending t = Mutex.protect t.m (fun () -> List.length t.loaded)
let idle t = Mutex.protect t.m (fun () -> t.loaded = [] && t.active = 0)
let parked t = Mutex.protect t.m (fun () -> t.parked)

let retrying t =
  Mutex.protect t.m (fun () ->
      List.filter_map
        (fun id ->
          Option.map (fun n -> (id, n)) (Hashtbl.find_opt t.failures id))
        t.loaded)

let running t =
  Mutex.protect t.m (fun () ->
      Hashtbl.fold
        (fun _ s acc ->
          match s.running with Some id -> id :: acc | None -> acc)
        t.slots [])

let loaded t = Mutex.protect t.m (fun () -> List.sort compare t.loaded)
let completed t = Mutex.protect t.m (fun () -> t.completed)

let cancel_key t k =
  Mutex.protect t.m (fun () ->
      match Hashtbl.find_opt t.slots k with
        | Some s -> Atomic.set s.cancel true
        | None -> ())

(* Returns once idle, not running, paused, or once a failure was noted after
   the settle began; under a stop, once the jobs then running have finished
   (§4.8: a stop takes no new job and cancels none). A cancelled wait ends. *)
let settle ?(timeout = settle_timeout) t =
  let began = Rt.now () in
  let deadline = began +. timeout in
  let rec loop () =
    let stop =
      Mutex.protect t.m (fun () ->
          (t.loaded = [] && t.active = 0)
          || (not t.started) || t.paused || t.last_failure_at >= began
          || List.for_all (fun id -> List.mem_assoc id t.parked) t.loaded
          || (Stop.requested () && t.active = 0))
    in
    if stop || Rt.now () >= deadline then ()
    else (
      match Rt.sleep 0.05 with () -> loop () | exception Rt.Cancelled -> ())
  in
  loop ()
