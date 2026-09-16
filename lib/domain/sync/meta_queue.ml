module Ek = Journal.Entry_key

module type S = sig
  type 'a io

  (** Metadata operations whose backend half is still owed. *)
  val pending : unit -> int

  (** Something was parked or the log overflowed; patience alone will not clear
      it. *)
  val degraded : unit -> bool

  val set_paused : bool -> unit
  val paused : unit -> bool
  val start : unit -> unit

  (** Take up whatever the log still owes that this queue is not already
      running, so a parked record is tried again without waiting for a restart.
  *)
  val rearm : unit -> unit io

  val drain : unit -> unit io
end

module type OVER = sig
  type 'a io

  module Make
      (_ : Conf.S with type 'a io = 'a io)
      (_ : File.Publishing with type 'a io := 'a io) :
    S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (Js : File_store.OVER with type 'a io := 'a Io.t)
    (Q :
      Durable_queue.QUEUE with type 'a io := 'a Io.t and type job := Wal.record)
    (W : Wal.OVER with type 'a io := 'a Io.t and type records := Q.Records.t) =
struct
  open Io_syntax.Make (Io)

  (* Bound before [Make] shadows [W] with its per-domain result. *)
  module Owed = W.Owed

  (* Past this a transient failure is taken for one that will not clear. An
     ordered queue holds a failing job at its head, so without a ceiling a single
     op that can never land stops every later one from reaching a peer for as
     long as the daemon runs; {!S.rearm} is what brings the parked one back. *)
  let max_attempts = 10

  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File.Publishing with type 'a io := 'a Io.t) :
    S with type 'a io := 'a Io.t = struct
    module Js = Js.Make (C)
    module W = W.Make (C)

    (* A put's bytes and entry are the upload queue's; everything else is
       ours. *)
    let is_metadata (r : Wal.record) =
      r.Wal.ops <> []
      && List.for_all (function `Put _ -> false | _ -> true) r.Wal.ops

    (* In memory, unlike the record's own count: what a ceiling is measuring is
       this run's attempts at a job the queue is holding, and a record carried
       over from an earlier run starts again rather than arriving already
       spent. *)
    let attempts : (string, int) Hashtbl.t = Hashtbl.create 16

    let count_failure id =
      let n = 1 + Option.value ~default:0 (Hashtbl.find_opt attempts id) in
      Hashtbl.replace attempts id n;
      n

    (* The record's id is the entry key: one unit of work keeps one name, from
       the local record through the published entry to the cursor a peer compares
       against. *)
    let run ~id (r : Wal.record) =
      match Ek.of_string id with
        | None -> return_unit
        | Some entry_key ->
            Io.catch
              (fun () ->
                let* () = F.backend_ops r.Wal.ops in
                (* Executed, then published, then the record goes: a crash in
                   either window leaves a record reconcile can finish from what
                   the backend says. The cursor is recorded rather than
                   published, so a drained backlog moves it once. *)
                let+ () =
                  W.discharge
                    ~publish:(fun ek ops ->
                      Js.write_journal_entry ~entry_key:ek ops)
                    ~cursor:(fun ek ->
                      Js.note_cursor ek;
                      return_unit)
                    entry_key r.Wal.ops
                in
                Hashtbl.remove attempts id)
              (function
                (* Settled some other way, so the record names nothing that is
                   still owed and goes rather than being retried. *)
                | Retry.Cancelled ->
                    Hashtbl.remove attempts id;
                    W.complete entry_key
                | exn ->
                    let n = count_failure id in
                    let* () =
                      W.note_failure entry_key (Backend.classify exn)
                        (Retry.reason exn)
                    in
                    if
                      n < max_attempts
                      || Backend.classify exn <> Retry.Transient
                    then Io.fail exn
                    else
                      Io.fail
                        (Backend.Backend_error
                           (Printf.sprintf "%s after %d attempts: %s"
                              (Ek.to_string entry_key) n (Retry.reason exn))))

    (* [Stop], not [Drop]: the record is what {!Replay} reconciles, what
       {!rearm} brings back and what stats reports as stuck, so parking must
       leave it behind. *)
    let queue =
      Q.ordered ~name:"metadata" ~log:W.log ~classify:Backend.classify
        ~poison:Durable_queue.Stop ~run ()

    (* Queued plus running: an ordered queue's [owed] counts what is waiting,
       and a caller draining on it alone would go on while the job that is
       publishing right now still owes its entry. *)
    let pending () =
      let s = Q.stats queue in
      s.Durable_queue.queued + s.Durable_queue.in_flight

    let degraded () = (Q.stats queue).Durable_queue.degraded
    let set_paused b = Q.set_paused queue b
    let paused () = Q.paused queue
    let adopt entry_key r = Q.adopt queue ~id:(Ek.to_string entry_key) r

    let rearm () =
      let* records = W.list () in
      iter_s
        (fun (entry_key, r) ->
          if is_metadata r then adopt entry_key r else return_unit)
        records

    let start () =
      (* Records a file operation wrote and handed over: taking one up is all
         this does with it, the write having already happened in the caller's own
         path. *)
      Owed.consume W.meta_owed (fun (entry_key, r) -> adopt entry_key r);
      (* No recovery here: {!Replay} reads the records itself and decides what is
         still owed against the shared journal, and {!rearm} covers what this
         queue parked. *)
      Q.start queue

    let drain () = Q.stop queue
  end
end
