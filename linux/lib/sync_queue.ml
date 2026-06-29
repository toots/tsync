type put_data = {
  key : string;
  src_path : string;
  entry_key : string;
  ops : Journal.op list;
}

type event =
  | Put of put_data
  | Delete of { key : string; entry_key : string; ops : Journal.op list }
  | Rename of {
      src_key : string;
      dst_key : string;
      src_is_dir : bool;
      dst_local_path : string;
      entry_key : string;
      put_ops : Journal.op list;
      rename_ops : Journal.op list;
    }
  | Mkdir of { key : string; entry_key : string; ops : Journal.op list }
  | Rmdir of { key : string; entry_key : string; ops : Journal.op list }
  | Evict of { key : string }

type slot = {
  mutable running : put_data;
  cancel : bool Atomic.t;
  mutable pending : put_data option;
}

type t = {
  store : File_store.t;
  slots : (string, slot) Hashtbl.t;
  slots_mtx : Mutex.t;
  queue : put_data Queue.t;
  queue_mtx : Mutex.t;
  queue_cond : Condition.t;
  on_version : entry_key:string -> unit;
  on_evict : key:string -> unit;
  stop : bool Atomic.t;
  mutable workers : unit Domain.t list;
}

(* enqueue: always locks queue_mtx; safe to call while slots_mtx is held
   (lock order is always slots_mtx → queue_mtx). *)
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

(* Cancel any in-flight Put for key. Returns true if a Put was cancelled. *)
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

(* ── Synchronous execution (non-Put operations) ──────────────────────────── *)

let exec_delete t key entry_key ops =
  try
    File_store.delete_file t.store ~key;
    ignore (File_store.write_journal_entry ~entry_key ops t.store);
    t.on_version ~entry_key
  with exn ->
    Log.err "sync_queue delete %s: %s" key (Printexc.to_string exn)

let exec_mkdir t key entry_key ops =
  try
    File_store.create_directory t.store ~key;
    ignore (File_store.write_journal_entry ~entry_key ops t.store);
    t.on_version ~entry_key
  with exn ->
    Log.err "sync_queue mkdir %s: %s" key (Printexc.to_string exn)

let exec_rmdir t key entry_key ops =
  try
    File_store.delete_dir t.store ~prefix:key;
    ignore (File_store.write_journal_entry ~entry_key ops t.store);
    t.on_version ~entry_key
  with exn ->
    Log.err "sync_queue rmdir %s: %s" key (Printexc.to_string exn)

let exec_rename t ~src_key ~dst_key ~src_is_dir entry_key ops =
  try
    if src_is_dir then
      File_store.rename_directory t.store ~src_prefix:src_key ~dst_prefix:dst_key
    else
      File_store.rename_file t.store ~src_key ~dst_key;
    ignore (File_store.write_journal_entry ~entry_key ops t.store);
    t.on_version ~entry_key
  with exn ->
    Log.err "sync_queue rename %s->%s: %s" src_key dst_key (Printexc.to_string exn)

(* ── Async Put execution ─────────────────────────────────────────────────── *)

let exec_put t slot { key; src_path; entry_key; ops } =
  if Atomic.get slot.cancel then Journal.delete_local_pending ~entry_key
  else
  try
    File_store.upload t.store ~key ~src_path ~cancel:slot.cancel ();
    (* A single-part upload has no inter-chunk cancel point so may complete
       even after cancel was set. Skip the journal write in that case to
       avoid a spurious Put entry landing after the Delete that cancelled us. *)
    if Atomic.get slot.cancel then
      Journal.delete_local_pending ~entry_key
    else begin
      Journal.delete_local_pending ~entry_key;
      ignore (File_store.write_journal_entry ~entry_key ops t.store);
      t.on_version ~entry_key;
    end
  with
  | S3_client.Cancelled
  | Unix.Unix_error (Unix.ENOENT, _, _) when Atomic.get slot.cancel ->
      Journal.delete_local_pending ~entry_key
  | exn ->
      Log.err "sync_queue put %s: %s" key (Printexc.to_string exn)

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
    end else begin
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

let make ~store ~auto_evict:_ ~on_version ~on_evict =
  let t =
    {
      store;
      slots = Hashtbl.create 64;
      slots_mtx = Mutex.create ();
      queue = Queue.create ();
      queue_mtx = Mutex.create ();
      queue_cond = Condition.create ();
      on_version;
      on_evict;
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

(* ── Public post interface ───────────────────────────────────────────────── *)

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

(* All non-Put events execute synchronously in the calling thread.
   Any in-flight Put for the affected key(s) is cancelled first. *)
let post t event =
  match event with
  | Put pd -> post_put t pd
  | Delete { key; entry_key; ops } ->
      ignore (cancel_put t key);
      exec_delete t key entry_key ops
  | Mkdir { key; entry_key; ops } ->
      exec_mkdir t key entry_key ops
  | Rmdir { key; entry_key; ops } ->
      exec_rmdir t key entry_key ops
  | Evict { key } ->
      ignore (cancel_put t key);
      (try File_store.evict t.store key; t.on_evict ~key
       with exn -> Log.err "sync_queue evict %s: %s" key (Printexc.to_string exn))
  | Rename { src_key; dst_key; src_is_dir; dst_local_path;
             entry_key; put_ops; rename_ops } ->
      let src_was_uploading = cancel_put t src_key in
      ignore (cancel_put t dst_key);
      if src_was_uploading && Sys.file_exists dst_local_path then begin
        (* src upload was in flight and local file is at dst; upload from there *)
        let pd = { key = dst_key; src_path = dst_local_path;
                   entry_key; ops = put_ops }
        in
        Journal.write_local_pending ~entry_key put_ops;
        post_put t pd
      end else
        (* src was not uploading, or local file is gone (auto-evict race):
           src is already on S3, so rename it there *)
        exec_rename t ~src_key ~dst_key ~src_is_dir entry_key rename_ops
