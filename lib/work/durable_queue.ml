open Lwt.Syntax

type poison = Stop | Drop
type stats = { queued : int; in_flight : int; degraded : bool; bytes : int64 }

module type JOB = sig
  type t

  val to_string : t -> string
  val of_string : string -> t option
end

(* Past this the queue is declared degraded and jobs are dropped. A job is a
   short line on disk, so this is a runaway backstop rather than a memory bound:
   reaching it means the target has not kept up for a very long time. *)
let default_max_queued = 100_000

(* A queue that is merely slow must not hold a command open forever. What is
   queued is on disk, so the next start picks it up. *)
let default_settle_timeout = 60.

(* Every queue in this process, whatever job it carries, so something about to
   exit can let them all settle without knowing who created them. Outside the
   functor deliberately: one per instantiation would quietly leave a second
   kind of queue out of every drain. *)
let registry : (unit -> unit Lwt.t) list ref = ref []
let register_settle f = registry := !registry @ [f]

let settle_all ?(timeout = default_settle_timeout) () =
  if !registry = [] then Lwt.return_unit
  else
    Lwt.pick
      [
        Lwt_list.iter_p (fun settle -> settle ()) !registry;
        (let* () = Lwt_unix.sleep timeout in
         Log.warn
           "durable queue: still behind after %.0fs, leaving the rest queued \
            on disk"
           timeout;
         Lwt.return_unit);
      ]

module Make (J : JOB) = struct
  module Records = struct
    type t = { dir : string; mutable seq : int }

    let create ~dir = { dir; seq = 0 }
    let path t id = Filename.concat t.dir id

    (* Fixed-width microseconds first, so the directory's lexicographic order is
       chronological, then a counter for two jobs within one microsecond and the
       pid to keep two processes apart. A plain counter would have them name
       different jobs the same file, and one would silently replace the other. *)
    let mint_id t =
      t.seq <- t.seq + 1;
      Printf.sprintf "%020Ld-%08d-%d"
        (Int64.of_float (Unix.gettimeofday () *. 1e6))
        t.seq (Unix.getpid ())

    let write t ~id job =
      let* () = Fs_util.mkdir_p t.dir in
      Fs_util.atomic_write (path t id) (J.to_string job)

    let read t id =
      Lwt.catch
        (fun () ->
          let+ body =
            Lwt_io.with_file ~mode:Lwt_io.Input (path t id) Lwt_io.read
          in
          J.of_string body)
        (fun _ -> Lwt.return_none)

    let update t id f =
      let* r = read t id in
      match r with None -> Lwt.return_unit | Some r -> write t ~id (f r)

    let complete t id = Fs_util.unlink_quiet (path t id)

    (* A record id leads with its timestamp; anything else is somebody's temp
       file, possibly a live one in another process, and is not ours to read or
       remove. An unreadable body is discarded: nothing can replay it, and
       leaving it would stall a queue on every start. *)
    let list t =
      let* exists = Lwt_unix_retry.file_exists t.dir in
      if not exists then Lwt.return_nil
      else
        let* names = Fs_util.readdir_list t.dir in
        let names =
          List.sort compare
            (List.filter
               (fun n -> n <> "" && n.[0] >= '0' && n.[0] <= '9')
               names)
        in
        let+ read_one =
          Lwt_list.map_s
            (fun id ->
              let* job = read t id in
              match job with
                | Some job -> Lwt.return_some (id, job)
                | None ->
                    Log.err "durable queue: unreadable record %s, discarding" id;
                    let+ () = complete t id in
                    None)
            names
        in
        List.filter_map Fun.id read_one
  end

  type entry = { id : string; job : J.t }

  (* At most one job per key, so a fresh post for a busy key cancels what is
     running and waits behind it as [pending]. *)
  type slot = {
    cancel : bool ref;
    mutable pending : entry option;
    mutable failures : int;
  }

  type topology =
    | Ordered
    | Keyed of {
        key : J.t -> string;
        weight : J.t -> int64;
        slots : (string, slot) Hashtbl.t;
        active : (string, entry) Hashtbl.t;
      }

  type t = {
    name : string;
    log : Records.t;
    poison : poison;
    max_queued : int;
    topo : topology;
    workers : int;
    run : id:string -> J.t -> cancel:bool ref -> unit Lwt.t;
    jobs : entry Queue.t;
    wake : unit Lwt_condition.t;
    settled : unit Lwt_condition.t;
    (* Held across recording one job, so the queue ends up in the order the ids
       say. Without it two concurrent writes can be named in one order and
       queued in the other, and a rename replayed backwards loses the file. *)
    recording : Lwt_mutex.t;
    mutable parked : int;  (** workers waiting for work *)
    mutable failures : int;  (** {!Ordered} only; {!Keyed} counts per slot *)
    mutable degraded : bool;
    paused : bool ref;
    stopping : bool ref;
    mutable running : unit Lwt.t list;
  }

  let base t =
    {
      name = t;
      log = Records.create ~dir:"";
      poison = Drop;
      max_queued = default_max_queued;
      topo = Ordered;
      workers = 1;
      run = (fun ~id:_ _ ~cancel:_ -> Lwt.return_unit);
      jobs = Queue.create ();
      wake = Lwt_condition.create ();
      settled = Lwt_condition.create ();
      recording = Lwt_mutex.create ();
      parked = 0;
      failures = 0;
      degraded = false;
      paused = ref false;
      stopping = ref false;
      running = [];
    }

  let active_count t =
    match t.topo with
      | Ordered -> t.workers - t.parked
      | Keyed k -> Hashtbl.length k.active

  let in_flight_keys t =
    match t.topo with
      | Ordered -> []
      | Keyed k -> Hashtbl.fold (fun key _ acc -> key :: acc) k.active []

  let owed t =
    match t.topo with
      | Ordered -> Queue.length t.jobs
      | Keyed k -> Hashtbl.length k.slots

  let idle t = Queue.is_empty t.jobs && active_count t = 0

  let stats t =
    let bytes =
      match t.topo with
        | Ordered -> 0L
        | Keyed k ->
            let add total e = Int64.add total (k.weight e.job) in
            Hashtbl.fold
              (fun _ e total -> add total e)
              k.active (Queue.fold add 0L t.jobs)
    in
    {
      queued = Queue.length t.jobs;
      in_flight = active_count t;
      degraded = t.degraded;
      bytes;
    }

  (* {1 Recording} *)

  let announce t = Lwt_condition.broadcast t.settled ()

  let enqueue t e =
    Queue.push e t.jobs;
    Lwt_condition.signal t.wake ()

  (* Dropped without waiting: the record names work whose data is no longer
     staged, which is exactly what a reconcile discards on the next start. *)
  let forget_pending t = function
    | Some e -> Lwt.async (fun () -> Records.complete t.log e.id)
    | None -> ()

  (* The job is on disk before the caller is told the write is done. Recorded in
     the caller's path rather than in the background, since a job only queued in
     memory is one a crash loses without anything left saying it was owed. *)
  let post ?id t job =
    if Queue.length t.jobs >= t.max_queued then begin
      if not t.degraded then begin
        t.degraded <- true;
        Log.err
          "%s: %d jobs queued, dropping writes — it will need tsync \
           resync-remote"
          t.name t.max_queued
      end;
      Lwt.return_unit
    end
    else
      Lwt_mutex.with_lock t.recording (fun () ->
          let id =
            match id with Some id -> id | None -> Records.mint_id t.log
          in
          let+ () = Records.write t.log ~id job in
          let e = { id; job } in
          match t.topo with
            | Ordered -> enqueue t e
            | Keyed k -> (
                let key = k.key job in
                match Hashtbl.find_opt k.slots key with
                  | None ->
                      Hashtbl.add k.slots key
                        { cancel = ref false; pending = None; failures = 0 };
                      enqueue t e
                  | Some slot ->
                      (* Whatever is running is about to be superseded, so stop
                         it rather than paying for bytes nobody will publish. *)
                      slot.cancel := true;
                      forget_pending t slot.pending;
                      slot.pending <- Some e))

  let cancel t key =
    match t.topo with
      | Ordered -> false
      | Keyed k -> (
          match Hashtbl.find_opt k.slots key with
            | None -> false
            | Some slot ->
                slot.cancel := true;
                forget_pending t slot.pending;
                slot.pending <- None;
                true)

  (* {1 Settling} *)

  (* A queue that has started failing ends the wait too. What it still owes is
     on disk and outlives the process, so holding a command open for a store
     that is down buys nothing. *)
  let rec settle t =
    if idle t then Lwt.return_unit
    else if t.failures > 0 then begin
      Log.warn "%s: target is down, leaving %d job(s) queued on disk" t.name
        (Queue.length t.jobs);
      Lwt.return_unit
    end
    else
      let* () = Lwt_condition.wait t.settled in
      settle t

  (* {1 The workers} *)

  let slot_of t e =
    match t.topo with
      | Ordered -> None
      | Keyed k -> Hashtbl.find_opt k.slots (k.key e.job)

  let note_failure t e =
    match slot_of t e with
      | Some slot ->
          slot.failures <- slot.failures + 1;
          slot.failures
      | None ->
          t.failures <- t.failures + 1;
          t.failures

  let clear_failures t e =
    (match slot_of t e with Some slot -> slot.failures <- 0 | None -> ());
    t.failures <- 0

  let poison_record t e exn =
    t.degraded <- true;
    match t.poison with
      | Drop ->
          Log.err "%s: %s (dropped; run tsync resync-remote)" t.name
            (Backend.reason exn);
          Records.complete t.log e.id
      | Stop ->
          (* The record stays: it names work still owed, and something outside
             the queue is expected to report or repair it. *)
          Log.err "%s: %s (not retrying)" t.name (Backend.reason exn);
          Lwt.return_unit

  (* An ordered queue keeps a failing job at the head, so what follows cannot
     overtake it. A keyed one puts it at the back: the keys are independent, and
     holding the head would stall every other key behind one that is failing. *)
  let rec loop t =
    if (Queue.is_empty t.jobs || !(t.paused)) && not !(t.stopping) then begin
      t.parked <- t.parked + 1;
      announce t;
      let* () = Lwt_condition.wait t.wake in
      t.parked <- t.parked - 1;
      loop t
    end
    else if Queue.is_empty t.jobs then Lwt.return_unit
    else begin
      let e = Queue.pop t.jobs in
      let cancel =
        match slot_of t e with Some slot -> slot.cancel | None -> ref false
      in
      (match t.topo with
        | Keyed k -> Hashtbl.replace k.active (k.key e.job) e
        | Ordered -> ());
      let* outcome =
        Lwt.catch
          (fun () ->
            let+ () = t.run ~id:e.id e.job ~cancel in
            `Done)
          (fun exn -> Lwt.return (`Failed exn))
      in
      (match t.topo with
        | Keyed k -> Hashtbl.remove k.active (k.key e.job)
        | Ordered -> ());
      let* requeue =
        match outcome with
          | `Done ->
              clear_failures t e;
              (* The work landed, so the record is no longer owed. A [run] that
                 completes it as part of its own ordering — publishing an entry
                 before dropping the record — has already unlinked it, and this
                 is then a no-op. *)
              let+ () = Records.complete t.log e.id in
              false
          | `Failed exn when Backend.classify exn = Backend.Transient ->
              let n = note_failure t e in
              (* The shared curve, with a cap measured against an outage rather
                 than a request: a queue has nobody waiting. *)
              let delay = Backend.backoff ~base:0.5 ~cap:300. n in
              Log.warn "%s: %s; retrying in %.1fs (%d)" t.name
                (Backend.reason exn) delay n;
              (* Before the sleep, so a drain waiting on this queue learns the
                 target is down now rather than a backoff later. *)
              announce t;
              let+ () = Lwt_unix.sleep delay in
              true
          | `Failed exn ->
              let+ () = poison_record t e exn in
              false
      in
      (* A replacement posted while this ran takes the key; otherwise the job
         either goes back for another try or the key is no longer owed. *)
      (match (slot_of t e, requeue && not !(t.stopping)) with
        | Some slot, _ when slot.pending <> None ->
            let next = Option.get slot.pending in
            slot.cancel := false;
            slot.pending <- None;
            enqueue t next
        | _, true -> enqueue t e
        | Some _, false -> (
            match t.topo with
              | Keyed k -> Hashtbl.remove k.slots (k.key e.job)
              | Ordered -> ())
        | None, false -> ());
      announce t;
      loop t
    end

  (* Everything a previous run left owed, in the order it was recorded. Under
     the same lock as {!post}, so a write arriving while this runs queues behind
     what it finds rather than ahead of it. *)
  let resume t =
    Lwt_mutex.with_lock t.recording @@ fun () ->
    let+ records = Records.list t.log in
    List.iter
      (fun (id, job) ->
        (match t.topo with
          | Keyed k ->
              let key = k.key job in
              if not (Hashtbl.mem k.slots key) then
                Hashtbl.add k.slots key
                  { cancel = ref false; pending = None; failures = 0 }
          | Ordered -> ());
        enqueue t { id; job })
      records;
    if records <> [] then
      Log.info "%s: resuming %d queued job(s)" t.name (List.length records)

  let start ?(recover = false) t =
    t.running <-
      List.init t.workers (fun _ ->
          let* () = if recover then resume t else Lwt.return_unit in
          loop t)

  let stop t =
    t.stopping := true;
    Lwt_condition.broadcast t.wake ();
    let* () = Lwt.join t.running in
    t.running <- [];
    Lwt.return_unit

  let set_paused t b =
    t.paused := b;
    if not b then Lwt_condition.broadcast t.wake ()

  let paused t = !(t.paused)

  let make ~name ~log ~poison ~max_queued ~topo ~workers ~run =
    let t =
      {
        (base name) with
        log;
        poison;
        max_queued;
        topo;
        workers;
        run;
        paused = ref false;
        stopping = ref false;
      }
    in
    register_settle (fun () -> settle t);
    t

  let ordered ?(max_queued = default_max_queued) ~name ~log ~poison ~run () =
    make ~name ~log ~poison ~max_queued ~topo:Ordered ~workers:1
      ~run:(fun ~id:_ job ~cancel:_ -> run job)

  let keyed ?(max_queued = default_max_queued) ?(workers = 1)
      ?(weight = fun _ -> 0L) ~name ~log ~key ~poison ~run () =
    make ~name ~log ~poison ~max_queued
      ~topo:
        (Keyed
           { key; weight; slots = Hashtbl.create 64; active = Hashtbl.create 8 })
      ~workers:(max 1 workers) ~run
end
