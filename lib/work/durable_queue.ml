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

(* Settable so a test need not wait the default minute to see a warning. *)
let stall_warning_interval = ref 60.
let set_stall_warning_interval s = stall_warning_interval := s

(* A queue that is merely slow must not hold a command open forever. What is
   queued is on disk, so the next start picks it up. *)
let default_settle_timeout = 60.

(* Every queue in this process, whatever job it carries, so something about to
   exit can let them all settle without knowing who created them. Outside the
   functor deliberately: one per instantiation would quietly leave a second
   kind of queue out of every drain. *)
let registry : (unit -> unit Lwt.t) list ref = ref []
let register_settle f = registry := !registry @ [f]

(* A record is on disk before the work it names has run, so a process reading
   another's log takes jobs that other one is about to run itself. A process
   holding records only in its own memory claims the log for as long as it
   lives, and one reading the log does so only when that claim is free.

   [lockf] rather than a marker file, because the kernel drops it when the
   holder dies: a killed command has to leave work claimable, not a directory
   nobody may touch. It sits beside the directory rather than in it, so a record
   stays the only thing that directory holds. *)
let lock_path dir = dir ^ ".owner"

let rec mkdir_p dir =
  if dir = "" || dir = "/" || Sys.file_exists dir then ()
  else (
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

(* A record lock merges with one the same process already holds, and closing any
   descriptor to the file drops every lock this process has on it, so a claim
   this process made is answered from here rather than from the kernel. *)
let owned : (string, Unix.file_descr) Hashtbl.t = Hashtbl.create 4

let claim dir =
  if not (Hashtbl.mem owned dir) then begin
    mkdir_p dir;
    let fd = Unix.openfile (lock_path dir) [Unix.O_RDWR; Unix.O_CREAT] 0o644 in
    match Unix.lockf fd Unix.F_TRLOCK 0 with
      | () -> Hashtbl.replace owned dir fd
      | exception _ ->
          (* Another claim is a second command against one target: both keep
             their own records and neither reads the log, so sharing it is
             what is expected. *)
          Unix.close fd
  end

(* The kernel does this when the holder exits, which is how a claim is given up;
   here for a caller standing in for that exit. *)
let release dir =
  match Hashtbl.find_opt owned dir with
    | None -> ()
    | Some fd ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ());
        Hashtbl.remove owned dir

(* [f] runs only if no process claims [dir]. *)
let with_claim dir f =
  if Hashtbl.mem owned dir then Lwt.return_unit
  else if not (Sys.file_exists dir) then Lwt.return_unit
  else (
    let fd = Unix.openfile (lock_path dir) [Unix.O_RDWR; Unix.O_CREAT] 0o644 in
    match Unix.lockf fd Unix.F_TLOCK 0 with
      | exception _ ->
          Unix.close fd;
          Lwt.return_unit
      | () ->
          Lwt.finalize f (fun () ->
              (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
              Unix.close fd;
              Lwt.return_unit))

(* Queues that read their log, so a caller can have them look again without
   knowing who created them. *)
let rescans : (unit -> unit Lwt.t) list ref = ref []
let register_rescan f = rescans := !rescans @ [f]
let rescan_all () = Lwt_list.iter_s (fun f -> f ()) !rescans

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
    type t = { dir : string; mutable seq : int; mutable dropped : int }

    let create ~dir = { dir; seq = 0; dropped = 0 }
    let dropped t = t.dropped
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

    (* A record that is simply gone was completed between the directory being
       read and this opening it, which is ordinary on a queue that is working; a
       body that will not parse is one nothing can replay; a read that failed for
       any other reason says nothing about the record at all.

       Only the middle may be dropped: collapsing them loses work to a full
       descriptor table or a bad sector, and prints the ordinary case as an
       error. *)
    let read t id =
      Lwt.catch
        (fun () ->
          let+ body =
            Lwt_io.with_file ~mode:Lwt_io.Input (path t id) Lwt_io.read
          in
          match J.of_string body with
            | Some job -> `Job job
            | None -> `Unreadable)
        (function
          | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return `Gone
          | exn -> Lwt.return (`Failed exn))

    let update t id f =
      let* r = read t id in
      match r with `Job r -> write t ~id (f r) | _ -> Lwt.return_unit

    let complete t id = Fs_util.unlink_quiet (path t id)

    (* A record id leads with its timestamp; anything else is somebody's temp
       file, possibly a live one in another process, and is not ours to read or
       remove. An unreadable body is discarded: nothing can replay it, and
       leaving it would stall a queue on every start.

       [wanted] decides from the id alone, before the body is opened: a sweep
       looking for what a queue has not already got is otherwise a read of every
       record it holds, which on a large backlog is tens of thousands of opens
       that end in the caller discarding all of them. *)
    let list ?(wanted = fun _ -> true) t =
      let* exists = Io_lwt.Retry.file_exists t.dir in
      if not exists then Lwt.return_nil
      else
        let* names = Fs_util.readdir_list t.dir in
        let names =
          List.sort compare
            (List.filter
               (fun n -> n <> "" && n.[0] >= '0' && n.[0] <= '9' && wanted n)
               names)
        in
        let+ read_one =
          Lwt_list.map_s
            (fun id ->
              let* job = read t id in
              match job with
                | `Job job -> Lwt.return_some (id, job)
                | `Gone -> Lwt.return_none
                | `Unreadable ->
                    t.dropped <- t.dropped + 1;
                    Log.err "durable queue: unreadable record %s, discarding" id;
                    let+ () = complete t id in
                    None
                | `Failed exn ->
                    (* Left where it is: the record still names work that is
                       owed, and the next sweep may read it. *)
                    Log.warn "durable queue: cannot read record %s: %s; leaving"
                      id (Printexc.to_string exn);
                    Lwt.return_none)
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
    (* Beside [run] because it is the same knowledge: whoever supplies the work
       is the only one who can say which of its failures will clear. *)
    classify : exn -> Retry.kind;
    jobs : entry Queue.t;
    (* Record ids this process holds in memory, so reading the log again adds
       only what nothing here is already going to run. *)
    loaded : (string, unit) Hashtbl.t;
    wake : unit Lwt_condition.t;
    settled : unit Lwt_condition.t;
    (* Held across recording one job, so the queue ends up in the order the ids
       say. Without it two concurrent writes can be named in one order and
       queued in the other, and a rename replayed backwards loses the file. *)
    recording : Lwt_mutex.t;
    mutable parked : int;  (** workers waiting for work *)
    mutable outcomes : int;  (** jobs run to an outcome, retries included *)
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
      classify = Retry.classify;
      jobs = Queue.create ();
      loaded = Hashtbl.create 64;
      wake = Lwt_condition.create ();
      settled = Lwt_condition.create ();
      recording = Lwt_mutex.create ();
      parked = 0;
      outcomes = 0;
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

  let in_flight t =
    match t.topo with
      | Ordered -> []
      | Keyed k -> Hashtbl.fold (fun _ e acc -> e.job :: acc) k.active []

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
      (* Whoever read the log did the discarding, which need not be the resume
         below, so the count is asked for here rather than latched there. *)
      degraded = t.degraded || Records.dropped t.log > 0;
      bytes;
    }

  let announce t = Lwt_condition.broadcast t.settled ()

  let enqueue t e =
    Hashtbl.replace t.loaded e.id ();
    Queue.push e t.jobs;
    Lwt_condition.signal t.wake ()

  let complete t id =
    Hashtbl.remove t.loaded id;
    Records.complete t.log id

  (* Dropped without waiting: the record names work whose data is no longer
     staged, which is exactly what a reconcile discards on the next start. *)
  let forget_pending t = function
    | Some e -> Lwt.async (fun () -> complete t e.id)
    | None -> ()

  (* The job is on disk before the caller is told the write is done. Recorded in
     the caller's path rather than in the background, since a job only queued in
     memory is one a crash loses without anything left saying it was owed. *)
  let post ?id t job =
    if Queue.length t.jobs >= t.max_queued then begin
      if not t.degraded then begin
        t.degraded <- true;
        Log.err
          "%s: %d jobs queued, dropping writes — it will need tsync mirror"
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
          Hashtbl.replace t.loaded id ();
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

  (* A queue that has started failing ends the wait too: what it owes is on disk
     and outlives the process, so holding a command open for a store that is
     down buys nothing. *)
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
          Log.err "%s: %s (dropped; run tsync mirror)" t.name (Retry.reason exn);
          complete t e.id
      | Stop ->
          (* The record stays: it names work still owed, and something outside
             the queue is expected to report or repair it. *)
          Log.err "%s: %s (not retrying)" t.name (Retry.reason exn);
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
      (* A job that failed and will be tried again still moved, so it counts. *)
      t.outcomes <- t.outcomes + 1;
      let* requeue =
        match outcome with
          | `Done ->
              clear_failures t e;
              (* The work landed, so the record is no longer owed. A [run] that
                 completes it as part of its own ordering — publishing an entry
                 before dropping the record — has already unlinked it, and this
                 is then a no-op. *)
              let+ () = complete t e.id in
              false
          | `Failed exn when t.classify exn = Retry.Transient ->
              (* Counted the same as a backend's own ladder: retries a queue
                 absorbs are still the link struggling, and a report that showed
                 only one of the two would understate it. *)
              Metrics.add_retry 1;
              if exn = Lwt_unix.Timeout then Metrics.add_timeout 1;
              let n = note_failure t e in
              (* The shared curve, with a cap measured against an outage rather
                 than a request: a queue has nobody waiting. *)
              let delay = Retry.backoff ~base:0.5 ~cap:300. n in
              Log.warn "%s: %s; retrying in %.1fs (%d)" t.name
                (Retry.reason exn) delay n;
              (* Before the sleep, so a drain waiting on this queue learns the
                 target is down now rather than a backoff later. *)
              announce t;
              let+ () = Lwt_unix.sleep delay in
              true
          | `Failed exn ->
              Metrics.add_failure 1;
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

  (* Everything a previous run left owed, in the order it was recorded, minus
     what this process already holds: the log is read more than once, and a
     record enqueued twice is a job run twice. Under the same lock as {!post},
     so a write arriving while this runs queues behind what it finds rather than
     ahead of it. *)
  let resume t =
    Lwt_mutex.with_lock t.recording @@ fun () ->
    let+ records =
      Records.list ~wanted:(fun id -> not (Hashtbl.mem t.loaded id)) t.log
    in
    (* A record nothing can replay is a write this target owes and will never
       make, which only a mirror puts back. *)
    if Records.dropped t.log > 0 && not t.degraded then begin
      t.degraded <- true;
      Log.err "%s: %d unreadable record(s) dropped — it will need tsync mirror"
        t.name (Records.dropped t.log)
    end;
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

  (* Whatever the log holds that nobody is running, if that can be established.
     A process still recording into this directory is running its own records
     from memory, and they are not this one's to take. *)
  let rescan t = with_claim t.log.Records.dir (fun () -> resume t)

  (* None of the ways a queue goes quiet raise, return or log, so what is
     reported is the absence: work owed and nothing finishing it. *)
  let rec watch_stalls t last =
    let* () = Lwt_unix.sleep !stall_warning_interval in
    if !(t.stopping) then Lwt.return_unit
    else begin
      let now = t.outcomes in
      if Queue.length t.jobs > 0 && now = last then
        Log.warn "%s: %d job(s) queued, none finished in %gs (%d/%d parked)"
          t.name (Queue.length t.jobs) !stall_warning_interval t.parked
          t.workers;
      watch_stalls t now
    end

  let start ?(recover = false) t =
    if recover then register_rescan (fun () -> rescan t)
    else claim t.log.Records.dir;
    t.running <-
      List.init t.workers (fun _ ->
          let p =
            let* () = if recover then rescan t else Lwt.return_unit in
            loop t
          in
          (* Awaited only by [stop], so a worker that failed is otherwise
             captured and never looked at. *)
          Lwt.on_failure p (fun exn ->
              Log.err "%s: worker stopped on %s; %d job(s) left queued" t.name
                (Printexc.to_string exn) (Queue.length t.jobs));
          p);
    Lwt.async (fun () -> watch_stalls t t.outcomes)

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

  let make ~name ~log ~poison ~max_queued ~topo ~workers ~classify ~run =
    let t =
      {
        (base name) with
        log;
        poison;
        max_queued;
        topo;
        workers;
        classify;
        run;
        paused = ref false;
        stopping = ref false;
      }
    in
    register_settle (fun () -> settle t);
    t

  let ordered ?(max_queued = default_max_queued) ~name ~log ~classify ~poison
      ~run () =
    make ~name ~log ~poison ~max_queued ~topo:Ordered ~workers:1 ~classify
      ~run:(fun ~id:_ job ~cancel:_ -> run job)

  let keyed ?(max_queued = default_max_queued) ?(workers = 1)
      ?(weight = fun _ -> 0L) ~name ~log ~key ~classify ~poison ~run () =
    make ~name ~log ~poison ~max_queued ~classify
      ~topo:
        (Keyed
           { key; weight; slots = Hashtbl.create 64; active = Hashtbl.create 8 })
      ~workers:(max 1 workers) ~run
end
