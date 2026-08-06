open Lwt.Syntax

module type S = sig
  val post :
    key:string -> entry_key:Journal.Entry_key.t -> ops:Journal.op list -> unit

  val cancel_put : string -> bool
  val idle : unit -> bool
  val pending : unit -> int
  val completed_count : unit -> int
  val set_paused : bool -> unit
  val paused : unit -> bool

  val start :
    upload:(key:string -> cancel:bool ref -> unit Lwt.t) ->
    on_cursor:(entry_key:Journal.Entry_key.t -> unit) ->
    on_upload_done:(key:string -> unit Lwt.t) ->
    unit

  val drain : unit -> unit Lwt.t
end

module Make (C : Conf.S) : S = struct
  module Fs = File_store.Make (C)
  module W = Wal.Make (C)

  type put_data = {
    key : string;
    entry_key : Journal.Entry_key.t;
    ops : Journal.op list;
  }

  (* [cancel] is polled between chunks, so setting it aborts at the next chunk
     boundary. [failures] drives the requeue backoff. *)
  type slot = {
    cancel : bool ref;
    mutable pending : put_data option;
    mutable failures : int;
  }

  (* Queue state is touched only from the Lwt event-loop thread, so no locks. *)
  let slots : (string, slot) Hashtbl.t = Hashtbl.create 64
  let queue : put_data Queue.t = Queue.create ()
  let queue_cond = Lwt_condition.create ()
  let stop = ref false
  let paused = ref false
  let workers : unit Lwt.t list ref = ref []

  let upload_fn : (key:string -> cancel:bool ref -> unit Lwt.t) ref =
    ref (fun ~key:_ ~cancel:_ -> Lwt.return_unit)

  let on_cursor_fn : (entry_key:Journal.Entry_key.t -> unit) ref =
    ref (fun ~entry_key:_ -> ())

  let on_upload_done_fn : (key:string -> unit Lwt.t) ref =
    ref (fun ~key:_ -> Lwt.return_unit)

  (* Fired off without blocking the synchronous post/cancel entry points. A
     failed unlink is not lost work: the record names a put whose data is no
     longer staged, which is exactly what {!Replay.reconcile} discards on the
     next start. *)
  let drop_pending entry_key = Lwt.async (fun () -> W.complete entry_key)

  let enqueue pd =
    Queue.add pd queue;
    Lwt_condition.signal queue_cond ()

  let add_slot key =
    Hashtbl.add slots key { cancel = ref false; pending = None; failures = 0 }

  let replace_pending slot pd =
    (match slot.pending with
      | Some { entry_key; _ } -> drop_pending entry_key
      | None -> ());
    slot.pending <- Some pd

  let clear_pending slot =
    (match slot.pending with
      | Some { entry_key; _ } -> drop_pending entry_key
      | None -> ());
    slot.pending <- None

  let cancel_put key =
    match Hashtbl.find_opt slots key with
      | Some slot ->
          slot.cancel := true;
          clear_pending slot;
          true
      | None -> false

  let idle () = Queue.is_empty queue && Hashtbl.length slots = 0

  (* Metrics: files with an active or queued upload, and uploads finished since
     start. *)
  let pending () = Hashtbl.length slots
  let completed = ref 0
  let completed_count () = !completed

  (* Returns [true] if the put failed transiently and should be requeued. *)
  let exec_put slot ({ key; entry_key; ops } : put_data) =
    if !(slot.cancel) then
      let+ () = W.complete entry_key in
      false
    else
      Lwt.catch
        (fun () ->
          let* () = !upload_fn ~key ~cancel:slot.cancel in
          if !(slot.cancel) then
            let+ () = W.complete entry_key in
            false
          else
            (* Executed, then published, then the record goes. A crash in the
               first window leaves a record saying the bytes are up and the
               entry is not, which is what reconcile finishes; a crash in the
               second leaves the same record, and reconcile finds the entry
               already published and drops it. Dropping the record first would
               leave the bytes uploaded, no entry for peers to read, and nothing
               saying anything was owed. *)
            let* () = W.advance entry_key Wal.Executed in
            let* (_ : Journal.Entry_key.t) =
              Fs.write_journal_entry ~entry_key ops
            in
            let* () = W.complete entry_key in
            !on_cursor_fn ~entry_key;
            incr completed;
            slot.failures <- 0;
            let+ () = !on_upload_done_fn ~key in
            false)
        (function
          | Backend.Cancelled ->
              let+ () = W.complete entry_key in
              false
          | Unix.Unix_error (Unix.ENOENT, _, _) ->
              let+ () = W.complete entry_key in
              false
          | exn -> (
              (* The record is never dropped on failure, or the file sits dirty
                 in the cache forever: auto-evict only runs after a successful
                 upload, and nothing else remembers the upload is owed. *)
              let kind = Backend.classify exn in
              let* () = W.note_failure entry_key kind (Backend.reason exn) in
              match kind with
                | Backend.Permanent ->
                    (* A 403, a read-only domain, a key the store refuses: the
                       same request will be refused again. Stop, and let the
                       record carry why — this used to spin forever. *)
                    Log.err "sync_queue put %s: %s; not retrying" key
                      (Backend.reason exn);
                    Lwt.return_false
                | Backend.Transient ->
                    slot.failures <- slot.failures + 1;
                    let delay =
                      Float.min 300.
                        (10. *. (2. ** float_of_int (slot.failures - 1)))
                    in
                    Log.err "sync_queue put %s: %s; requeue %d in %.0fs" key
                      (Backend.reason exn) slot.failures delay;
                    let+ () = Lwt_unix.sleep delay in
                    true))

  (* Parking on [queue_cond] is how a worker waits for either more work or a
     resume. [stop] wins over [paused], or a paused queue would never drain. *)
  let rec worker_loop () =
    if (Queue.is_empty queue || !paused) && not !stop then
      let* () = Lwt_condition.wait queue_cond in
      worker_loop ()
    else if Queue.is_empty queue then Lwt.return_unit
    else begin
      let pd = Queue.pop queue in
      let slot = Hashtbl.find slots pd.key in
      let* retry = exec_put slot pd in
      (match (slot.pending, retry && not !stop) with
        | Some next, _ ->
            slot.cancel := false;
            slot.pending <- None;
            enqueue next
        | None, true -> enqueue pd
        | None, false -> Hashtbl.remove slots pd.key);
      worker_loop ()
    end

  (* Below [worker_loop], so the loop above still sees the ref this shadows. *)
  let set_paused b =
    paused := b;
    if not b then Lwt_condition.broadcast queue_cond ()

  let paused () = !paused

  let start ~upload ~on_cursor ~on_upload_done =
    upload_fn := upload;
    on_cursor_fn := on_cursor;
    on_upload_done_fn := on_upload_done;
    workers := List.init (max 1 C.max_uploads) (fun _ -> worker_loop ())

  let drain () =
    stop := true;
    Lwt_condition.broadcast queue_cond ();
    let* () = Lwt.join !workers in
    workers := [];
    Lwt.return_unit

  let post ~key ~entry_key ~ops =
    let pd = { key; entry_key; ops } in
    match Hashtbl.find_opt slots key with
      | None ->
          add_slot key;
          enqueue pd
      | Some slot ->
          slot.cancel := true;
          replace_pending slot pd
end
