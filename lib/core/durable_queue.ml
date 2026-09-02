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

(* A record is on disk before the work it names has run, so a process reading
   another's log takes jobs that other one is about to run itself. A process
   holding records only in its own memory claims the log for as long as it
   lives, and one reading the log does so only when that claim is free.

   [lockf] rather than a marker file, because the kernel drops it when the
   holder dies: a killed command has to leave work claimable, not a directory
   nobody may touch. It sits beside the directory rather than in it, so a record
   stays the only thing that directory holds. *)
let lock_path dir = dir ^ ".owner"

(* A record lock merges with one the same process already holds, and closing any
   descriptor to the file drops every lock this process has on it, so a claim
   this process made is answered from here rather than from the kernel. *)
let owned : (string, Unix.file_descr) Hashtbl.t = Hashtbl.create 4

let claim dir =
  if not (Hashtbl.mem owned dir) then begin
    Fs.mkdir_p_sync dir;
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

(** The calls this makes of a filesystem, spelled as {!Fs} spells them so that
    one can be handed over as it stands. *)
module type FILES = sig
  type 'a io

  val mkdir_p : string -> unit io
  val atomic_write : string -> string -> unit io
  val readdir_list : string -> string list io
  val readdir_list_quiet : string -> string list io
  val unlink_quiet : string -> unit io
  val is_directory : string -> bool io
  val read_file : string -> [ `Body of string | `Gone | `Failed of exn ] io
end

module type RECORDS = sig
  type 'a io
  type job
  type t

  val create : dir:string -> t
  val write : t -> id:string -> job -> unit io
  val update : t -> string -> (job -> job) -> unit io
  val complete : t -> string -> unit io
  val list : ?wanted:(string -> bool) -> t -> (string * job) list io
  val dropped : t -> int
end

module type QUEUE = sig
  type 'a io
  type job

  module Records : RECORDS with type 'a io := 'a io and type job := job

  type t

  val ordered :
    ?max_queued:int ->
    name:string ->
    log:Records.t ->
    classify:(exn -> Retry.kind) ->
    poison:poison ->
    run:(job -> unit io) ->
    unit ->
    t

  val keyed :
    ?max_queued:int ->
    ?workers:int ->
    ?weight:(job -> int64) ->
    name:string ->
    log:Records.t ->
    key:(job -> string) ->
    classify:(exn -> Retry.kind) ->
    poison:poison ->
    run:(id:string -> job -> cancel:bool ref -> unit io) ->
    unit ->
    t

  val post : ?id:string -> t -> job -> unit io
  val adopt : t -> id:string -> job -> unit io
  val start : ?recover:bool -> t -> unit
  val cancel : t -> string -> bool
  val set_paused : t -> bool -> unit
  val paused : t -> bool
  val stop : t -> unit io
  val stats : t -> stats
  val in_flight : t -> job list
  val owed : t -> int
  val settle_key : t -> string -> unit io
end

module type S = sig
  type 'a io

  val settle_all : ?timeout:float -> unit -> unit io
  val register_settle : (unit -> unit io) -> unit
  val rescan_all : unit -> unit io

  module Make (J : JOB) : QUEUE with type 'a io := 'a io and type job := J.t
end

module Make
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Lock : Lock.S with type 'a io := 'a Io.t)
    (Files : FILES with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  (* [f] runs only if no process claims [dir]. *)
  let with_claim dir f =
    if Hashtbl.mem owned dir then Io.return ()
    else if not (Sys.file_exists dir) then Io.return ()
    else (
      let fd =
        Unix.openfile (lock_path dir) [Unix.O_RDWR; Unix.O_CREAT] 0o644
      in
      match Unix.lockf fd Unix.F_TLOCK 0 with
        | exception _ ->
            Unix.close fd;
            Io.return ()
        | () ->
            Io.finalize f (fun () ->
                (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
                Unix.close fd;
                Io.return ()))

  (* Every queue in this process, whatever job it carries, so something about to
     exit can let them all settle without knowing who created them. *)
  let registry : (unit -> unit Io.t) list ref = ref []
  let register_settle f = registry := !registry @ [f]

  (* Queues that read their log, so a caller can have them look again without
     knowing who created them. *)
  let rescans : (unit -> unit Io.t) list ref = ref []
  let register_rescan f = rescans := !rescans @ [f]
  let rescan_all () = iter_s (fun f -> f ()) !rescans

  let settle_all ?(timeout = default_settle_timeout) () =
    if !registry = [] then Io.return ()
    else
      Io.catch
        (fun () ->
          Clock.with_timeout timeout (fun () ->
              Io.iter_p (fun settle -> settle ()) !registry))
        (fun exn ->
          if Clock.is_timeout exn then begin
            Log.warn
              "durable queue: still behind after %.0fs, leaving the rest \
               queued on disk"
              timeout;
            Io.return ()
          end
          else Io.fail exn)

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
        let* () = Files.mkdir_p t.dir in
        Files.atomic_write (path t id) (J.to_string job)

      (* A record that is simply gone was completed between the directory being
         read and this opening it, which is ordinary on a queue that is working; a
         body that will not parse is one nothing can replay; a read that failed for
         any other reason says nothing about the record at all.

         Only the middle may be dropped: collapsing them loses work to a full
         descriptor table or a bad sector, and prints the ordinary case as an
         error. *)
      let read t id =
        let+ body = Files.read_file (path t id) in
        match body with
          | `Gone -> `Gone
          | `Failed exn -> `Failed exn
          | `Body body -> (
              match J.of_string body with
                | Some job -> `Job job
                | None -> `Unreadable)

      let update t id f =
        let* r = read t id in
        match r with `Job r -> write t ~id (f r) | _ -> Io.return ()

      let complete t id = Files.unlink_quiet (path t id)

      (* A record id leads with its timestamp; anything else is somebody's temp
         file, possibly a live one in another process, and is not ours to read or
         remove. An unreadable body is discarded: nothing can replay it, and
         leaving it would stall a queue on every start.

         [wanted] decides from the id alone, before the body is opened: a sweep
         looking for what a queue has not already got is otherwise a read of every
         record it holds, which on a large backlog is tens of thousands of opens
         that end in the caller discarding all of them. *)
      let list ?(wanted = fun _ -> true) t =
        let* exists = Files.is_directory t.dir in
        if not exists then Io.return []
        else
          let* names = Files.readdir_list t.dir in
          let names =
            List.sort compare
              (List.filter
                 (fun n -> n <> "" && n.[0] >= '0' && n.[0] <= '9' && wanted n)
                 names)
          in
          let+ read_one =
            map_s
              (fun id ->
                let* job = read t id in
                match job with
                  | `Job job -> Io.return @@ Some (id, job)
                  | `Gone -> Io.return None
                  | `Unreadable ->
                      t.dropped <- t.dropped + 1;
                      Log.err "durable queue: unreadable record %s, discarding"
                        id;
                      let+ () = complete t id in
                      None
                  | `Failed exn ->
                      (* Left where it is: the record still names work that is
                         owed, and the next sweep may read it. *)
                      Log.warn
                        "durable queue: cannot read record %s: %s; leaving" id
                        (Printexc.to_string exn);
                      Io.return None)
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
      run : id:string -> J.t -> cancel:bool ref -> unit Io.t;
      (* Beside [run] because it is the same knowledge: whoever supplies the work
         is the only one who can say which of its failures will clear. *)
      classify : exn -> Retry.kind;
      jobs : entry Queue.t;
      (* Record ids this process holds in memory, so reading the log again adds
         only what nothing here is already going to run. *)
      loaded : (string, unit) Hashtbl.t;
      wake : Lock.condition;
      settled : Lock.condition;
      (* Held across recording one job, so the queue ends up in the order the ids
         say. Without it two concurrent writes can be named in one order and
         queued in the other, and a rename replayed backwards loses the file. *)
      recording : Lock.mutex;
      mutable parked : int;  (** workers waiting for work *)
      mutable outcomes : int;  (** jobs run to an outcome, retries included *)
      mutable failures : int;  (** {!Ordered} only; {!Keyed} counts per slot *)
      mutable degraded : bool;
      paused : bool ref;
      stopping : bool ref;
      mutable running : unit Io.t list;
    }

    let base t =
      {
        name = t;
        log = Records.create ~dir:"";
        poison = Drop;
        max_queued = default_max_queued;
        topo = Ordered;
        workers = 1;
        run = (fun ~id:_ _ ~cancel:_ -> Io.return ());
        classify = Retry.classify;
        jobs = Queue.create ();
        loaded = Hashtbl.create 64;
        wake = Lock.condition ();
        settled = Lock.condition ();
        recording = Lock.mutex ();
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

    let announce t = Lock.broadcast t.settled

    let enqueue t e =
      Hashtbl.replace t.loaded e.id ();
      Queue.push e t.jobs;
      Lock.signal t.wake

    let complete t id =
      Hashtbl.remove t.loaded id;
      Records.complete t.log id

    (* Dropped without waiting: the record names work whose data is no longer
       staged, which is exactly what a reconcile discards on the next start. *)
    let forget_pending t = function
      | Some e -> Io.async (fun () -> complete t e.id)
      | None -> ()

    (* Taking the slot and queueing, which is all {!adopt} is and all {!post}
       adds to its write. *)
    let take t ~id job =
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
                  (* Whatever is running is about to be superseded, so stop it
                     rather than paying for bytes nobody will publish. *)
                  slot.cancel := true;
                  forget_pending t slot.pending;
                  slot.pending <- Some e)

    let full t =
      if Queue.length t.jobs >= t.max_queued then begin
        if not t.degraded then begin
          t.degraded <- true;
          Log.err
            "%s: %d jobs queued, dropping writes — it will need tsync mirror"
            t.name t.max_queued
        end;
        true
      end
      else false

    (* The job is on disk before the caller is told the write is done. Recorded in
       the caller's path rather than in the background, since a job only queued in
       memory is one a crash loses without anything left saying it was owed. *)
    let post ?id t job =
      if full t then Io.return ()
      else
        Lock.with_lock t.recording (fun () ->
            let id =
              match id with Some id -> id | None -> Records.mint_id t.log
            in
            let+ () = Records.write t.log ~id job in
            take t ~id job)

    (* A job already on disk, for a caller that wrote it: the record is theirs
       and this only takes it up. Under the same lock as {!post}, and idempotent
       on [id], so a record signalled twice is queued once. *)
    let adopt t ~id job =
      if full t then Io.return ()
      else
        Lock.with_lock t.recording (fun () ->
            if Hashtbl.mem t.loaded id then Io.return ()
            else Io.return (take t ~id job))

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
      if idle t then Io.return ()
      else if t.failures > 0 then begin
        Log.warn "%s: target is down, leaving %d job(s) queued on disk" t.name
          (Queue.length t.jobs);
        Io.return ()
      end
      else
        let* () = Lock.wait t.settled in
        settle t

    (* One key's job leaving the queue: done, dropped or cancelled. Ends the
       way [settle] does once that key has started failing -- the record is on
       disk and outlives the process -- so a caller is never held for a store
       that is down. An ordered queue has no keys, so it is the whole queue. *)
    let rec settle_key t key =
      match t.topo with
        | Ordered -> settle t
        | Keyed k -> (
            match Hashtbl.find_opt k.slots key with
              | None -> Io.return ()
              | Some slot when slot.failures > 0 -> Io.return ()
              | Some _ ->
                  let* () = Lock.wait t.settled in
                  settle_key t key)

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
            Log.err "%s: %s (dropped; run tsync mirror)" t.name
              (Retry.reason exn);
            complete t e.id
        | Stop ->
            (* The record stays: it names work still owed, and something outside
               the queue is expected to report or repair it. *)
            Log.err "%s: %s (not retrying)" t.name (Retry.reason exn);
            Io.return ()

    (* An ordered queue keeps a failing job at the head, so what follows cannot
       overtake it. A keyed one puts it at the back: the keys are independent, and
       holding the head would stall every other key behind one that is failing. *)
    let rec loop t =
      if (Queue.is_empty t.jobs || !(t.paused)) && not !(t.stopping) then begin
        t.parked <- t.parked + 1;
        announce t;
        let* () = Lock.wait t.wake in
        t.parked <- t.parked - 1;
        loop t
      end
      else if Queue.is_empty t.jobs then Io.return ()
      else begin
        let e = Queue.pop t.jobs in
        let cancel =
          match slot_of t e with Some slot -> slot.cancel | None -> ref false
        in
        (match t.topo with
          | Keyed k -> Hashtbl.replace k.active (k.key e.job) e
          | Ordered -> ());
        let* outcome =
          Io.catch
            (fun () ->
              let+ () = t.run ~id:e.id e.job ~cancel in
              `Done)
            (fun exn -> Io.return (`Failed exn))
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
                if Clock.is_timeout exn then Metrics.add_timeout 1;
                let n = note_failure t e in
                (* The shared curve, with a cap measured against an outage rather
                   than a request: a queue has nobody waiting. *)
                let delay = Retry.backoff ~base:0.5 ~cap:300. n in
                Log.warn "%s: %s; retrying in %.1fs (%d)" t.name
                  (Retry.reason exn) delay n;
                (* Before the sleep, so a drain waiting on this queue learns the
                   target is down now rather than a backoff later. *)
                announce t;
                let+ () = Clock.sleep delay in
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
      Lock.with_lock t.recording @@ fun () ->
      let+ records =
        Records.list ~wanted:(fun id -> not (Hashtbl.mem t.loaded id)) t.log
      in
      (* A record nothing can replay is a write this target owes and will never
         make, which only a mirror puts back. *)
      if Records.dropped t.log > 0 && not t.degraded then begin
        t.degraded <- true;
        Log.err
          "%s: %d unreadable record(s) dropped — it will need tsync mirror"
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
      let* () = Clock.sleep !stall_warning_interval in
      if !(t.stopping) then Io.return ()
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
              let* () = if recover then rescan t else Io.return () in
              loop t
            in
            (* Awaited only by [stop], so a worker that failed is otherwise
               captured and never looked at. *)
            Io.catch
              (fun () -> p)
              (fun exn ->
                Log.err "%s: worker stopped on %s; %d job(s) left queued" t.name
                  (Printexc.to_string exn) (Queue.length t.jobs);
                Io.fail exn));
      Io.async (fun () -> watch_stalls t t.outcomes)

    let stop t =
      t.stopping := true;
      Lock.broadcast t.wake;
      let* () = Io.join t.running in
      t.running <- [];
      Io.return ()

    let set_paused t b =
      t.paused := b;
      if not b then Lock.broadcast t.wake

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
             {
               key;
               weight;
               slots = Hashtbl.create 64;
               active = Hashtbl.create 8;
             })
        ~workers:(max 1 workers) ~run
  end
end
