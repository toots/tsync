module Ek = Journal.Entry_key

(* What this needs below it. *)
module type S = sig
  type 'a io

  (** Files with an active or queued upload. *)
  val pending : unit -> int
  val uploading : unit -> Logical_key.t list

  (** Bytes still owed: everything queued plus everything in flight. Counted
      whole per file, so a file half sent still counts for its full size. *)
  val pending_bytes : unit -> int64

  (** Uploads completed since the daemon started. *)
  val completed_count : unit -> int

  (** Park the workers between uploads. Queued work is kept, so {!pending} keeps
      reporting it, and {!drain} still runs to completion. Not persisted: a
      restart resumes. *)
  val set_paused : bool -> unit

  val paused : unit -> bool
  val start : on_upload_done:(key:Logical_key.t -> unit io) -> unit
  val drain : unit -> unit io
end

module type OVER = sig
  type 'a io

  module Make
      (_ : Conf.S with type 'a io = 'a io)
      (_ : File.Owing with type 'a io := 'a io) : S with type 'a io := 'a io
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
      (F : File.Owing with type 'a io := 'a Io.t) :
    S with type 'a io := 'a Io.t = struct
    module Js = Js.Make (C)
    module Lk = Logical_key.Make (C)
    module W = W.Make (C)

    (* The queue's own slot identity, not a name: one string per file so a second
       write to it takes the first one's place. *)
    let slot_of r =
      match F.record_key r with Some k -> Logical_key.to_string k | None -> ""

    let on_upload_done_fn : (key:Logical_key.t -> unit Io.t) ref =
      ref (fun ~key:_ -> return_unit)

    let completed = ref 0
    let completed_count () = !completed

    (* The record's id is the entry key: one unit of work keeps one name, from the
       local record through the published journal entry to the cursor a peer
       compares against. *)
    let run ~id (r : Wal.record) ~cancel =
      match Ek.of_string id with
        | None -> return_unit
        | Some entry_key -> (
            let abandon () = W.complete entry_key in
            match F.record_key r with
              (* No op, so no file and nothing to publish; the record would
                 otherwise become an entry naming nothing. *)
              | None ->
                  Log.err "%s: record names no file, dropping"
                    (Ek.to_string entry_key);
                  abandon ()
              | Some key ->
                  Io.catch
                    (fun () ->
                      if !cancel then abandon ()
                      else
                        let* () = F.upload ~cancel key in
                        if !cancel then abandon ()
                        else
                          (* Executed, then published, then the record goes: a crash in
                       either window leaves a record reconcile can finish from what
                       the backend says. Dropping the record first would leave the
                       bytes uploaded, no entry for peers to read, and nothing
                       saying anything was owed. The cursor is recorded rather
                       than published: a busy queue owes a move per file, and
                       they collapse to the newest. *)
                          let* () =
                            W.discharge
                              ~publish:(fun ek ops ->
                                Js.write_journal_entry ~entry_key:ek ops)
                              ~cursor:(fun ek ->
                                Js.note_cursor ek;
                                return_unit)
                              entry_key r.Wal.ops
                          in
                          incr completed;
                          !on_upload_done_fn ~key)
                    (function
                      (* Superseded, or the staged bytes are gone: nothing is owed any
                   more, so the record goes rather than being retried. *)
                      | Retry.Cancelled | Unix.Unix_error (Unix.ENOENT, _, _) ->
                          abandon ()
                      | exn ->
                          (* The record is never dropped on a real failure, or the file
                       sits dirty in the cache forever: nothing else remembers the
                       upload is owed. *)
                          let* () =
                            W.note_failure entry_key (Backend.classify exn)
                              (Retry.reason exn)
                          in
                          Io.fail exn))

    (* [Stop], not [Drop]: the record is what {!Replay} reconciles and what stats
       reports as stuck, so a permanent failure has to leave it behind. *)
    let queue =
      Q.keyed ~workers:(max 1 C.max_uploads) ~weight:F.record_size
        ~name:"upload" ~log:W.log ~key:slot_of ~classify:Backend.classify
        ~poison:Durable_queue.Stop ~run ()

    (* [Prepared]: whatever staged data the caller read is what this names, so the
       upload is owed from here on. *)
    let post ~entry_key (r : Wal.record) =
      Q.post ~id:(Ek.to_string entry_key) queue
        { r with Wal.state = Wal.Prepared }

    let cancel_put key = Q.cancel queue key
    let pending () = Q.owed queue
    let uploading () = List.filter_map F.record_key (Q.in_flight queue)
    let pending_bytes () = (Q.stats queue).Durable_queue.bytes
    let set_paused b = Q.set_paused queue b
    let paused () = Q.paused queue

    let start ~on_upload_done =
      on_upload_done_fn := on_upload_done;
      F.set_in_flight uploading;
      F.set_canceller (fun key -> cancel_put (Logical_key.to_string key));
      (* Records a file operation wrote and handed over. Taking one up is all this
         does with it -- the write already happened, in the caller's own path,
         which is what makes a crash there leave something saying the work is
         owed -- and it happens there too, so a close returns with the upload
         queued and whatever follows can cancel it. *)
      Owed.consume W.owed (fun (entry_key, r) ->
          Q.adopt queue ~id:(Ek.to_string entry_key) r);
      (* No recovery here: {!Replay} reads the records itself, decides what is
         still owed against the shared journal, and re-writes only that. *)
      Q.start queue

    let drain () = Q.stop queue
  end
end
