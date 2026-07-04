open Lwt.Syntax

module type S = sig
  val post : key:string -> entry_key:string -> ops:Journal.op list -> unit
  val cancel_put : string -> bool
  val idle : unit -> bool
  val pending : unit -> int
  val completed_count : unit -> int

  val start :
    upload:(key:string -> cancel:bool ref -> unit Lwt.t) ->
    on_cursor:(entry_key:string -> unit) ->
    on_upload_done:(key:string -> unit Lwt.t) ->
    unit

  val drain : unit -> unit Lwt.t
end

module Make (C : Conf.S) : S = struct
  module Fs = File_store.Make (C)
  module J = Journal.Make (C)

  type put_data = { key : string; entry_key : string; ops : Journal.op list }

  (* [cancel] is polled by the upload between chunks; setting it aborts the
     in-flight upload at the next chunk boundary. *)
  type slot = { cancel : bool ref; mutable pending : put_data option }

  (* All queue state is touched only from the Lwt event-loop thread (workers and
     the post/cancel entry points all run there), so no locks are needed. *)
  let slots : (string, slot) Hashtbl.t = Hashtbl.create 64
  let queue : put_data Queue.t = Queue.create ()
  let queue_cond = Lwt_condition.create ()
  let stop = ref false
  let workers : unit Lwt.t list ref = ref []

  let upload_fn : (key:string -> cancel:bool ref -> unit Lwt.t) ref =
    ref (fun ~key:_ ~cancel:_ -> Lwt.return_unit)

  let on_cursor_fn : (entry_key:string -> unit) ref =
    ref (fun ~entry_key:_ -> ())

  let on_upload_done_fn : (key:string -> unit Lwt.t) ref =
    ref (fun ~key:_ -> Lwt.return_unit)

  (* Pending-file cleanup is a best-effort disk unlink; fire it off without
     blocking the synchronous post/cancel entry points.
     ponytail: fire-and-forget unlink; make post/cancel return Lwt only if a
     failed unlink ever needs to be surfaced. *)
  let drop_pending entry_key =
    Lwt.async (fun () -> J.delete_local_pending ~entry_key)

  let enqueue pd =
    Queue.add pd queue;
    Lwt_condition.signal queue_cond ()

  let add_slot key =
    Hashtbl.add slots key { cancel = ref false; pending = None }

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

  let exec_put slot ({ key; entry_key; ops } : put_data) =
    if !(slot.cancel) then J.delete_local_pending ~entry_key
    else
      Lwt.catch
        (fun () ->
          let* () = !upload_fn ~key ~cancel:slot.cancel in
          if !(slot.cancel) then J.delete_local_pending ~entry_key
          else
            let* () = J.delete_local_pending ~entry_key in
            let* (_ : string) = Fs.write_journal_entry ~entry_key ops in
            !on_cursor_fn ~entry_key;
            incr completed;
            !on_upload_done_fn ~key)
        (function
          | Backend.Cancelled -> J.delete_local_pending ~entry_key
          | Unix.Unix_error (Unix.ENOENT, _, _) ->
              J.delete_local_pending ~entry_key
          | exn ->
              Log.err "sync_queue put %s: %s" key (Printexc.to_string exn);
              Lwt.return_unit)

  let rec worker_loop () =
    if Queue.is_empty queue then
      if !stop then Lwt.return_unit
      else
        let* () = Lwt_condition.wait queue_cond in
        worker_loop ()
    else begin
      let pd = Queue.pop queue in
      let slot = Hashtbl.find slots pd.key in
      let* () = exec_put slot pd in
      (match slot.pending with
        | None -> Hashtbl.remove slots pd.key
        | Some next ->
            slot.cancel := false;
            slot.pending <- None;
            enqueue next);
      worker_loop ()
    end

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
