module Ek = Journal.Entry_key

module type S = sig
  type 'a io

  (** Metadata operations whose backend half is still owed. *)
  val pending : unit -> int

  (** An operation is parked: it fails in a way waiting will not clear, and
      later ones publish past it until {!rearm} finds it fixed. *)
  val degraded : unit -> bool

  val set_paused : bool -> unit
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

  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File.Publishing with type 'a io := 'a Io.t) :
    S with type 'a io := 'a Io.t = struct
    module Js = Js.Make (C)
    module W = W.Make (C)

    (* Only the link failing clears by waiting. A failure of this client's own
       -- its state, its code -- fails the same way on every try, and an ordered
       queue retrying it at the head would publish nothing after it for good. *)
    let classify = function
      | Invalid_argument _ | Failure _ | Not_found | Assert_failure _
      | Match_failure _ ->
          Retry.Permanent
      | exn -> Backend.classify exn

    (* What is parked right now, where the queue's own flag latches for the life
       of the process and would go on reporting an operation {!rearm} landed. *)
    let parked : (string, unit) Hashtbl.t = Hashtbl.create 4

    (* Read again rather than taken from the job: a conflict settled since this
       was queued may have rewritten where the work lands. *)
    let publish entry_key =
      let* current = W.find entry_key in
      let owed = Option.fold ~none:[] ~some:(fun c -> c.Wal.ops) current in
      let* ops = F.backend_ops owed in
      match ops with
        (* The store was never told of what this names. *)
        | [] -> W.complete entry_key
        | ops ->
            (* The cursor is recorded rather than published, so a drained
               backlog moves it once. *)
            W.discharge
              ~publish:(fun ek ops -> Js.write_journal_entry ~entry_key:ek ops)
              ~cursor:(fun ek ->
                Js.note_cursor ek;
                return_unit)
              entry_key ops

    (* The record's id is the entry key: one unit of work keeps one name, from
       the local record through the published entry to the cursor a peer compares
       against. *)
    let run ~id (_ : Wal.record) =
      match Ek.of_string id with
        | None -> return_unit
        | Some entry_key ->
            Io.catch
              (fun () ->
                let+ () = publish entry_key in
                Hashtbl.remove parked id)
              (function
                (* Settled some other way, so the record names nothing that is
                   still owed and goes rather than being retried. *)
                | Retry.Cancelled ->
                    Hashtbl.remove parked id;
                    W.complete entry_key
                | exn ->
                    let kind = classify exn in
                    if kind = Retry.Permanent then Hashtbl.replace parked id ();
                    let* () =
                      W.note_failure entry_key kind (Retry.reason exn)
                    in
                    Io.fail exn)

    (* [Stop], not [Drop]: the record is what {!Replay} reconciles, what
       {!rearm} brings back and what stats reports as stuck, so parking must
       leave it behind. *)
    let queue =
      Q.ordered ~name:"metadata" ~log:W.log ~classify ~poison:Durable_queue.Stop
        ~run ()

    (* Queued plus running: an ordered queue's [owed] counts what is waiting,
       and a caller draining on it alone would go on while the job that is
       publishing right now still owes its entry. *)
    let pending () =
      let s = Q.stats queue in
      s.Durable_queue.queued + s.Durable_queue.in_flight

    let degraded () = Hashtbl.length parked > 0
    let set_paused b = Q.set_paused queue b
    let adopt entry_key r = Q.adopt queue ~id:(Ek.to_string entry_key) r

    let rearm () =
      let* records = W.owed_metadata () in
      (* An intent is an op still inside its local half, which hands the record
         over itself when that is done. *)
      iter_s
        (fun (entry_key, (r : Wal.record)) ->
          if r.Wal.state = Wal.Prepared then adopt entry_key r else return_unit)
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
