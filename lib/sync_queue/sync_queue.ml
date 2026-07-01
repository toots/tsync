module type S = sig
  val post :
    key:string ->
    src_path:string ->
    entry_key:string ->
    ops:Journal.op list ->
    unit

  val cancel_put : string -> bool

  val start :
    upload:(key:string -> cancel:bool Atomic.t -> unit) ->
    on_version:(entry_key:string -> unit) ->
    on_upload_done:(key:string -> unit) ->
    unit

  val drain : unit -> unit
end

module Make(C : Conf.S) : S = struct
  module Fs = File_store.Make(C)
  module J = Journal.Make(C)

  type put_data = {
    key : string;
    src_path : string;
    entry_key : string;
    ops : Journal.op list;
  }

  type slot = {
    mutable running : put_data;
    cancel : bool Atomic.t;
    mutable pending : put_data option;
  }

  let slots : (string, slot) Hashtbl.t = Hashtbl.create 64
  let slots_mtx = Mutex.create ()
  let queue : put_data Queue.t = Queue.create ()
  let queue_mtx = Mutex.create ()
  let queue_cond = Condition.create ()
  let stop = Atomic.make false
  let workers : unit Domain.t list ref = ref []
  let upload_fn : (key:string -> cancel:bool Atomic.t -> unit) ref =
    ref (fun ~key:_ ~cancel:_ -> ())
  let on_version_fn : (entry_key:string -> unit) ref =
    ref (fun ~entry_key:_ -> ())
  let on_upload_done_fn : (key:string -> unit) ref =
    ref (fun ~key:_ -> ())

  let enqueue pd =
    Mutex.lock queue_mtx;
    Queue.add pd queue;
    Condition.signal queue_cond;
    Mutex.unlock queue_mtx

  let add_slot key pd =
    Hashtbl.add slots key
      { running = pd; cancel = Atomic.make false; pending = None }

  let replace_pending slot pd =
    (match slot.pending with
      | Some { entry_key; _ } -> J.delete_local_pending ~entry_key
      | None -> ());
    slot.pending <- Some pd

  let clear_pending slot =
    (match slot.pending with
      | Some { entry_key; _ } -> J.delete_local_pending ~entry_key
      | None -> ());
    slot.pending <- None

  let cancel_put key =
    Mutex.lock slots_mtx;
    let was_uploading =
      match Hashtbl.find_opt slots key with
        | Some slot ->
            Atomic.set slot.cancel true;
            clear_pending slot;
            true
        | None -> false
    in
    Mutex.unlock slots_mtx;
    was_uploading

  let exec_put slot ({ key; entry_key; ops; _ } : put_data) =
    if Atomic.get slot.cancel then J.delete_local_pending ~entry_key
    else (
      try
        !upload_fn ~key ~cancel:slot.cancel;
        if Atomic.get slot.cancel then
          J.delete_local_pending ~entry_key
        else begin
          J.delete_local_pending ~entry_key;
          ignore (Fs.write_journal_entry ~entry_key ops);
          !on_version_fn ~entry_key;
          !on_upload_done_fn ~key
        end
      with
        | S3_client.Cancelled ->
            J.delete_local_pending ~entry_key
        | Unix.Unix_error (Unix.ENOENT, _, _) ->
            J.delete_local_pending ~entry_key
        | exn -> Log.err "sync_queue put %s: %s" key (Printexc.to_string exn))

  let worker_loop () =
    let keep_running = ref true in
    while !keep_running do
      Mutex.lock queue_mtx;
      while Queue.is_empty queue && not (Atomic.get stop) do
        Condition.wait queue_cond queue_mtx
      done;
      if Queue.is_empty queue then begin
        Mutex.unlock queue_mtx;
        keep_running := false
      end
      else begin
        let pd = Queue.pop queue in
        Mutex.unlock queue_mtx;
        Mutex.lock slots_mtx;
        let slot = Hashtbl.find slots pd.key in
        Mutex.unlock slots_mtx;
        exec_put slot pd;
        Mutex.lock slots_mtx;
        (match slot.pending with
          | None -> Hashtbl.remove slots pd.key
          | Some next ->
              slot.running <- next;
              Atomic.set slot.cancel false;
              slot.pending <- None;
              enqueue next);
        Mutex.unlock slots_mtx
      end
    done

  let start ~upload ~on_version ~on_upload_done =
    upload_fn := upload;
    on_version_fn := on_version;
    on_upload_done_fn := on_upload_done;
    workers := List.init 4 (fun _ -> Domain.spawn (fun () -> worker_loop ()))

  let drain () =
    Atomic.set stop true;
    Mutex.lock queue_mtx;
    Condition.broadcast queue_cond;
    Mutex.unlock queue_mtx;
    List.iter Domain.join !workers;
    workers := []

  let post ~key ~src_path ~entry_key ~ops =
    let pd = { key; src_path; entry_key; ops } in
    Mutex.lock slots_mtx;
    (match Hashtbl.find_opt slots key with
      | None ->
          add_slot key pd;
          enqueue pd
      | Some slot ->
          Atomic.set slot.cancel true;
          replace_pending slot pd);
    Mutex.unlock slots_mtx
end
