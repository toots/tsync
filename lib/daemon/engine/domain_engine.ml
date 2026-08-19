open Lwt.Syntax

(* The per-domain sync engine: upload queue, file ops, journal/IPC handler and
   change poller. A frontend instantiates one [Make(C)] per domain and calls
   [start] on its own Lwt loop, supplying only the callbacks that differ between
   presentations. *)
module Make (C : Conf.S) = struct
  module Sq = Sync_queue.Make (C)
  module F = File.Make (C) (Sq)
  module Ih = Ipc_handler.Make (C) (F)
  module Sp = Sync_poller.Make (C) (F)
  module Rp = Replay.Make (C) (F)
  module Mf = Manifest.Make (C)
  module Fs = File_store.Make (C)

  (* Also nudged after each upload, but downloads grow the store too. The same
     sweep looks for deferred work a one-shot command left behind, which is
     bounded by how long that work may sit rather than by the store's growth. *)
  let housekeeping_interval = 60.

  (* An upload owes a cursor bump once its journal entry lands, one per file on a
     busy queue. The cursor only moves forward, so a batch collapses to its
     newest: hold the pending value and publish on a timer rather than paying a
     PUT per upload. Metadata ops bypass this — [File.with_journal] bumps
     synchronously, since a peer waiting on a rename should not wait out the
     interval. *)
  let cursor_flush_interval = 2.
  let pending_cursor : Journal.Entry_key.t option ref = ref None

  let set_pending_cursor ~entry_key =
    match !pending_cursor with
      | Some prev when Journal.Entry_key.compare prev entry_key >= 0 -> ()
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

  (* The manifest tree, which a caller needs before it can resolve a key at all.
     Separate from {!start_queue} because a read-only command needs this and
     nothing else. *)
  let init () = Mf.init ()

  (* Everything needed before a caller may stage or publish, and nothing that
     outlives the call: a one-shot command starts here and drains, where a
     daemon goes on to {!start}.

     [Rp.reconcile] is queued before anything is served, so a file edited before
     a crash is not left looking unsynced. The queue must be running first:
     recovery goes through it, for the journal entry and cursor bump an upload
     owes. *)
  let start_queue ?(on_upload_done = fun ~key:_ -> Lwt.return_unit) () =
    let* () = init () in
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_cursor:set_pending_cursor
      ~on_upload_done:(fun ~key ->
        let* () = on_upload_done ~key in
        F.enforce_chunk_cap ());
    Rp.reconcile ()

  (* [freshness] is required, not optional: a frontend that says nothing here
     leaves its users looking at a stale view, and an omitted argument is
     indistinguishable from a considered "nothing to do". *)
  let start ~freshness ~on_upload_done () =
    let* () = start_queue ~on_upload_done () in
    Sp.start
      ~on_changed:
        (match freshness with
          | Frontend.Notify f -> f
          | Frontend.Revalidates -> fun _ -> ())
      ();
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
          let* () = sweep "deferred rescan" Durable_queue.rescan_all in
          loop ()
        in
        loop ());
    Lwt.return_unit

  (* Uploads produce backfill work, so the queue settles first and the backends
     second, with the last cursor bump published in between: by then the queue
     owes none, and a peer must not wait for this client to run again to learn
     what it already uploaded. *)
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
