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

  (** Keys of the files a worker is uploading right now. *)
  val uploading : unit -> string list

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
    upload:(key:string -> cancel:bool ref -> unit Lwt.t) ->
    on_upload_done:(key:string -> unit Lwt.t) ->
    unit

  val drain : unit -> unit Lwt.t
end

module Make (C : Conf.S) : S = struct
  module Fs = File_store.Make (C)
  module W = Wal.Make (C)
  module Q = Wal.Q

  (* The file a record is about, and what it will cost to send. Both derived
     from the ops rather than carried alongside them, so the two cannot disagree
     about which file a record names. *)
  let op_key = function
    | `Put (k, _) | `Delete k | `Mkdir (k, _) | `Rmdir (k, _) -> k
    | `Rename { Journal.dst; _ } -> dst

  let key_of (r : Wal.record) =
    match r.Wal.ops with op :: _ -> C.domain_prefix ^ op_key op | [] -> ""

  (* Only a [`Put] carries bytes; the other ops are metadata the backend answers
     in one round trip. *)
  let size_of (r : Wal.record) =
    List.fold_left
      (fun total op ->
        match op with `Put (_, size) -> Int64.add total size | _ -> total)
      0L r.Wal.ops

  let upload_fn : (key:string -> cancel:bool ref -> unit Lwt.t) ref =
    ref (fun ~key:_ ~cancel:_ -> Lwt.return_unit)

  let on_upload_done_fn : (key:string -> unit Lwt.t) ref =
    ref (fun ~key:_ -> Lwt.return_unit)

  let completed = ref 0
  let completed_count () = !completed

  (* The record's id is the entry key: one unit of work keeps one name, from the
     local record through the published journal entry to the cursor a peer
     compares against. *)
  let run ~id (r : Wal.record) ~cancel =
    match Ek.of_string id with
      | None -> Lwt.return_unit
      | Some entry_key ->
          let key = key_of r in
          let abandon () = W.complete entry_key in
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
              | Backend.Cancelled | Unix.Unix_error (Unix.ENOENT, _, _) ->
                  abandon ()
              | exn ->
                  (* The record is never dropped on a real failure, or the file
                     sits dirty in the cache forever: nothing else remembers the
                     upload is owed. *)
                  let* () =
                    W.note_failure entry_key (Backend.classify exn)
                      (Backend.reason exn)
                  in
                  Lwt.fail exn)

  (* [Stop], not [Drop]: the record is what {!Replay} reconciles and what stats
     reports as stuck, so a permanent failure has to leave it behind. *)
  let queue =
    Q.keyed ~workers:(max 1 C.max_uploads) ~weight:size_of ~name:"upload"
      ~log:W.log ~key:key_of ~poison:Durable_queue.Stop ~run ()

  (* [Prepared]: whatever staged data the caller read is what this names, so the
     upload is owed from here on. *)
  let post ~entry_key (r : Wal.record) =
    Q.post ~id:(Ek.to_string entry_key) queue
      { r with Wal.state = Wal.Prepared }

  let cancel_put key = Q.cancel queue key
  let pending () = Q.owed queue
  let uploading () = Q.in_flight_keys queue
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
