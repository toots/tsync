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

  (* Periodic housekeeping: keep the chunk store under the cap (nudged after each
     upload too, but downloads grow it as well) and drop handoff copies a frontend
     never claimed. *)
  let housekeeping_interval = 60.

  let start ?on_changed ~on_cursor ~on_upload_done () =
    let* () = Mf.init () in
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_cursor
      ~on_upload_done:(fun ~key ->
        let* () = on_upload_done ~key in
        F.enforce_chunk_cap ());
    (* Anything the staged tree still owes predates this process: queue it before
       serving, so a file edited before a crash is not left looking unsynced. The
       queue must be running first — recovery goes through it, for the journal
       entry and cursor bump an upload owes. *)
    let* () = F.recover_staged () in
    Sp.start ?on_changed ();
    Lwt.async (fun () ->
        let sweep what f =
          Lwt.catch f (fun exn ->
              Log.err "%s: %s" what (Printexc.to_string exn);
              Lwt.return_unit)
        in
        let rec loop () =
          let* () = Lwt_unix.sleep housekeeping_interval in
          let* () = sweep "chunk cap sweep" F.enforce_chunk_cap in
          let* () = sweep "handoff reap" F.reap_handoff in
          loop ()
        in
        loop ());
    Lwt.return_unit

  (* Uploads produce backfill work, so the queue settles first and the backends
     second. *)
  let drain () =
    let* () = Sq.drain () in
    Backend.drain ()

  let stats_fields () =
    [
      ("pendingUploads", `Int (Sq.pending ()));
      ("uploadsCompleted", `Int (Sq.completed_count ()));
    ]
end
