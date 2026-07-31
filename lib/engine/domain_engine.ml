open Lwt.Syntax

(* The per-domain sync engine shared by all frontends: the upload queue, file
   ops, journal/IPC handler and the change poller. A frontend instantiates one
   [Make(C)] per domain and calls [start] on its own Lwt loop, supplying the
   callbacks that differ between presentations; everything below is identical
   across frontends, so it lives here once. *)
module Make (C : Conf.S) = struct
  module Sq = Sync_queue.Make (C)
  module F = File.Make (C) (Sq)
  module Ih = Ipc_handler.Make (C) (F)
  module Sp = Sync_poller.Make (C) (F)
  module Mf = Manifest.Make (C)
  module Fs = File_store.Make (C)

  (* Periodic housekeeping: keep the chunk store under the cap, nudged after each
     upload too, but downloads grow it as well. *)
  let housekeeping_interval = 60.

  (* ── Cursor batching ──────────────────────────────────────────────────────
     An upload owes a cursor bump once its journal entry lands, and a busy queue
     owes one per file. The cursor only ever moves forward, so a batch of them
     collapses to its newest — hold the pending value and publish it on a timer
     rather than paying a backend PUT per upload. Metadata ops do not come
     through here: [File.with_journal] bumps synchronously, because a peer
     waiting on a rename should not wait out this interval. *)
  let cursor_flush_interval = 2.
  let pending_cursor : string option ref = ref None

  let set_pending_cursor ~entry_key =
    match !pending_cursor with
      | Some prev when prev >= entry_key -> ()
      | _ -> pending_cursor := Some entry_key

  let flush_cursor () =
    let ek = !pending_cursor in
    pending_cursor := None;
    match ek with
      | None -> Lwt.return_unit
      | Some ek ->
          Lwt.catch
            (fun () -> Fs.bump_cursor ek)
            (fun exn ->
              Log.err "bump_cursor: %s" (Printexc.to_string exn);
              Lwt.return_unit)

  let cursor_flusher () =
    let rec loop () =
      let* () = Lwt_unix.sleep cursor_flush_interval in
      let* () = flush_cursor () in
      loop ()
    in
    loop ()

  let start ?on_changed ~on_upload_done () =
    let* () = Mf.init () in
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_cursor:set_pending_cursor
      ~on_upload_done:(fun ~key ->
        let* () = on_upload_done ~key in
        F.enforce_chunk_cap ());
    (* Anything the staged tree still owes predates this process: queue it before
       serving, so a file edited before a crash is not left looking unsynced. The
       queue must be running first — recovery goes through it, for the journal
       entry and cursor bump an upload owes. *)
    let* () = F.recover_staged () in
    Sp.start ?on_changed ();
    Lwt.async cursor_flusher;
    Lwt.async (fun () ->
        let sweep what f =
          Lwt.catch f (fun exn ->
              Log.err "%s: %s" what (Printexc.to_string exn);
              Lwt.return_unit)
        in
        let rec loop () =
          let* () = Lwt_unix.sleep housekeeping_interval in
          let* () = sweep "chunk cap sweep" F.enforce_chunk_cap in
          loop ()
        in
        loop ());
    Lwt.return_unit

  (* Uploads produce backfill work, so the queue settles first and the backends
     second. The last batch of cursor bumps is published in between: the queue
     has stopped owing them by then, and a peer must not have to wait for this
     client to run again to learn what it already uploaded. *)
  let drain () =
    let* () = Sq.drain () in
    let* () = flush_cursor () in
    Backend.drain ()

  let stats_fields () =
    [
      ("pendingUploads", `Int (Sq.pending ()));
      ("uploadsCompleted", `Int (Sq.completed_count ()));
    ]
end
