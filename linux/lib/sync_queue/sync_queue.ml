type put_data = {
  key : string;
  src_path : string;
  entry_key : string;
  ops : Journal.op list;
}

type event = Put of put_data

type slot = {
  mutable running : put_data;
  cancel : bool Atomic.t;
  mutable pending : put_data option;
}

type t = {
  store : File_store.t;
  upload_fn : key:string -> cancel:bool Atomic.t -> unit;
  slots : (string, slot) Hashtbl.t;
  slots_mtx : Mutex.t;
  queue : put_data Queue.t;
  queue_mtx : Mutex.t;
  queue_cond : Condition.t;
  on_version : entry_key:string -> unit;
  on_upload_done : key:string -> unit;
  stop : bool Atomic.t;
  mutable workers : unit Domain.t list;
}

let enqueue t pd =
  Mutex.lock t.queue_mtx;
  Queue.add pd t.queue;
  Condition.signal t.queue_cond;
  Mutex.unlock t.queue_mtx

let add_slot t key pd =
  Hashtbl.add t.slots key
    { running = pd; cancel = Atomic.make false; pending = None }

let replace_pending slot pd =
  (match slot.pending with
    | Some { entry_key; _ } -> Journal.delete_local_pending ~entry_key
    | None -> ());
  slot.pending <- Some pd

let clear_pending slot =
  (match slot.pending with
    | Some { entry_key; _ } -> Journal.delete_local_pending ~entry_key
    | None -> ());
  slot.pending <- None

let cancel_put t key =
  Mutex.lock t.slots_mtx;
  let was_uploading =
    match Hashtbl.find_opt t.slots key with
      | Some slot ->
          Atomic.set slot.cancel true;
          clear_pending slot;
          true
      | None -> false
  in
  Mutex.unlock t.slots_mtx;
  was_uploading

let exec_put t slot ({ key; entry_key; ops; _ } : put_data) =
  if Atomic.get slot.cancel then Journal.delete_local_pending ~entry_key
  else (
    try
      t.upload_fn ~key ~cancel:slot.cancel;
      if Atomic.get slot.cancel then Journal.delete_local_pending ~entry_key
      else begin
        Journal.delete_local_pending ~entry_key;
        ignore (File_store.write_journal_entry ~entry_key ops t.store);
        t.on_version ~entry_key;
        t.on_upload_done ~key
      end
    with
      | S3_client.Cancelled -> Journal.delete_local_pending ~entry_key
      | Unix.Unix_error (Unix.ENOENT, _, _) ->
          Journal.delete_local_pending ~entry_key
      | exn -> Log.err "sync_queue put %s: %s" key (Printexc.to_string exn))

let worker_loop t =
  let keep_running = ref true in
  while !keep_running do
    Mutex.lock t.queue_mtx;
    while Queue.is_empty t.queue && not (Atomic.get t.stop) do
      Condition.wait t.queue_cond t.queue_mtx
    done;
    if Queue.is_empty t.queue then begin
      Mutex.unlock t.queue_mtx;
      keep_running := false
    end
    else begin
      let pd = Queue.pop t.queue in
      Mutex.unlock t.queue_mtx;
      Mutex.lock t.slots_mtx;
      let slot = Hashtbl.find t.slots pd.key in
      Mutex.unlock t.slots_mtx;
      exec_put t slot pd;
      Mutex.lock t.slots_mtx;
      (match slot.pending with
        | None -> Hashtbl.remove t.slots pd.key
        | Some next ->
            slot.running <- next;
            Atomic.set slot.cancel false;
            slot.pending <- None;
            enqueue t next);
      Mutex.unlock t.slots_mtx
    end
  done

let make ~store ~upload ~on_version ~on_upload_done =
  let t =
    {
      store;
      upload_fn = upload;
      slots = Hashtbl.create 64;
      slots_mtx = Mutex.create ();
      queue = Queue.create ();
      queue_mtx = Mutex.create ();
      queue_cond = Condition.create ();
      on_version;
      on_upload_done;
      stop = Atomic.make false;
      workers = [];
    }
  in
  t.workers <- List.init 4 (fun _ -> Domain.spawn (fun () -> worker_loop t));
  t

let drain t =
  Atomic.set t.stop true;
  Mutex.lock t.queue_mtx;
  Condition.broadcast t.queue_cond;
  Mutex.unlock t.queue_mtx;
  List.iter Domain.join t.workers

let post_put t pd =
  Mutex.lock t.slots_mtx;
  (match Hashtbl.find_opt t.slots pd.key with
    | None ->
        add_slot t pd.key pd;
        enqueue t pd
    | Some slot ->
        Atomic.set slot.cancel true;
        replace_pending slot pd);
  Mutex.unlock t.slots_mtx

let post t (Put pd) = post_put t pd
