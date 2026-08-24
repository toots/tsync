open Lwt.Syntax
module Ek = Journal.Entry_key

module type S = sig
  (** Record the work and queue it. Returns once the record is durable, not once
      the upload has landed. [entry_key] names the record and goes on to name
      the journal entry the upload publishes; the file is read from the record's
      ops, so there is nowhere for the two to disagree about which one this is.

      The whole record is the caller's to supply, so re-queueing one carries
      forward what it has already been through. *)
  val post : entry_key:Journal.Entry_key.t -> Wal.record -> unit Lwt.t

  val cancel_put : string -> bool

  (** Files with an active or queued upload. *)
  val pending : unit -> int

  (** The files a worker is uploading right now. *)
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

  val start :
    upload:(key:Logical_key.t -> cancel:bool ref -> unit Lwt.t) ->
    on_upload_done:(key:Logical_key.t -> unit Lwt.t) ->
    unit

  val drain : unit -> unit Lwt.t
end

module Make (C : Conf.S) : S = struct
  module Lk = Logical_key.Make (C)
  module Fs = File_store.Make (C)
  module W = Wal.Make (C)
  module Q = Wal.Q

  (* The file a record is about, and what it will cost to send. Both derived
     from the ops rather than carried alongside them, so the two cannot disagree
     about which file a record names.

     The op says whether it names a folder, so the key it yields does too: a
     directory rename read back as a file publishes an entry a peer replays as
     one. *)
  let op_key = function
    | `Put (k, _) | `Delete k -> Lk.file k
    | `Mkdir (k, _) | `Rmdir (k, _) -> Lk.dir k
    | `Rename { Journal.dst; is_dir; _ } ->
        if is_dir then Lk.dir dst else Lk.file dst

  let key_of (r : Wal.record) =
    match r.Wal.ops with op :: _ -> Some (op_key op) | [] -> None

  (* The queue's own slot identity, not a name: one string per file so a second
     write to it takes the first one's place. *)
  let slot_of r =
    match key_of r with Some k -> Logical_key.to_string k | None -> ""

  (* Only a [`Put] carries bytes; the other ops are metadata the backend answers
     in one round trip. *)
  let size_of (r : Wal.record) =
    List.fold_left
      (fun total op ->
        match op with `Put (_, size) -> Int64.add total size | _ -> total)
      0L r.Wal.ops

  let upload_fn : (key:Logical_key.t -> cancel:bool ref -> unit Lwt.t) ref =
    ref (fun ~key:_ ~cancel:_ -> Lwt.return_unit)

  let on_upload_done_fn : (key:Logical_key.t -> unit Lwt.t) ref =
    ref (fun ~key:_ -> Lwt.return_unit)

  let completed = ref 0
  let completed_count () = !completed

  (* The record's id is the entry key: one unit of work keeps one name, from the
     local record through the published journal entry to the cursor a peer
     compares against. *)
  let run ~id (r : Wal.record) ~cancel =
    match Ek.of_string id with
      | None -> Lwt.return_unit
      | Some entry_key -> (
          let abandon () = W.complete entry_key in
          match key_of r with
            (* No op, so no file and nothing to publish; the record would
               otherwise become an entry naming nothing. *)
            | None ->
                Log.err "%s: record names no file, dropping"
                  (Ek.to_string entry_key);
                abandon ()
            | Some key ->
                Lwt.catch
                  (fun () ->
                    if !cancel then abandon ()
                    else
                      let* () = !upload_fn ~key ~cancel in
                      if !cancel then abandon ()
                      else
                        (* Executed, then published, then the record goes: a crash in
                     either window leaves a record reconcile can finish from what
                     the backend says. Dropping the record first would leave the
                     bytes uploaded, no entry for peers to read, and nothing
                     saying anything was owed. *)
                        let* () = W.advance entry_key Wal.Executed in
                        let* (_ : Ek.t) =
                          Fs.write_journal_entry ~entry_key r.Wal.ops
                        in
                        let* () = W.complete entry_key in
                        (* The entry this queue just published owes a cursor bump,
                     and nothing above knows an entry landed. Recorded rather
                     than published: a busy queue owes one per file, and they
                     collapse to the newest. *)
                        Fs.note_cursor entry_key;
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
                        Lwt.fail exn))

  (* [Stop], not [Drop]: the record is what {!Replay} reconciles and what stats
     reports as stuck, so a permanent failure has to leave it behind. *)
  let queue =
    Q.keyed ~workers:(max 1 C.max_uploads) ~weight:size_of ~name:"upload"
      ~log:W.log ~key:slot_of ~classify:Backend.classify
      ~poison:Durable_queue.Stop ~run ()

  (* [Prepared]: whatever staged data the caller read is what this names, so the
     upload is owed from here on. *)
  let post ~entry_key (r : Wal.record) =
    Q.post ~id:(Ek.to_string entry_key) queue
      { r with Wal.state = Wal.Prepared }

  let cancel_put key = Q.cancel queue key
  let pending () = Q.owed queue
  let uploading () = List.filter_map key_of (Q.in_flight queue)
  let pending_bytes () = (Q.stats queue).Durable_queue.bytes
  let set_paused b = Q.set_paused queue b
  let paused () = Q.paused queue

  let start ~upload ~on_upload_done =
    upload_fn := upload;
    on_upload_done_fn := on_upload_done;
    (* No recovery here: {!Replay} reads the records itself, decides what is
       still owed against the shared journal, and re-posts only that. *)
    Q.start queue

  let drain () = Q.stop queue
end
