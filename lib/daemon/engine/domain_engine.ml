open Lwt.Syntax

(* How a frontend lets a user see a change another client made. Required rather
   than optional because a frontend with no answer looks like one with nothing to
   do: that is how the FUSE mount came to serve a file under its name from before
   another client renamed it, unopenable, until the mount was taken down. *)
type freshness =
  | Notify of (string -> unit)
    (* Hand each changed key to the presentation layer as it happens, for a
         layer that keeps its own state and has to be told. *)
  | Revalidates
(* Nothing has to be pushed, because the layer asks again on every
         access. *)

(* What a frontend is given for one domain: its file operations, the request
   handler built over them, and the background work that keeps it converging
   with the store.

   Whether this process is the one doing that work was decided before the
   frontend was handed this, so [start] is called unconditionally and there is
   nothing here to ask about. *)
module type Domain = sig
  module F : File_ops.S
  module Ih : Ipc_handler.S

  val start :
    freshness:freshness ->
    ?on_upload_done:(key:string -> unit Lwt.t) ->
    unit ->
    unit Lwt.t

  val drain : unit -> unit Lwt.t
  val stats_fields : unit -> (string * Yojson.Safe.t) list
end

module type S = sig
  include Domain

  val init : unit -> unit Lwt.t

  val start_queue :
    ?on_upload_done:(key:string -> unit Lwt.t) -> unit -> unit Lwt.t

  (* The half every process serving the domain runs. {!Passive} is what a
     process that is not keeping the domain fresh gets. *)
  val start_local :
    ?on_upload_done:(key:string -> unit Lwt.t) -> unit -> unit Lwt.t
end

module Make (C : Conf.S) : S = struct
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
  (* Every process serving this domain runs its own upload queue: the workers
     are in-memory and each posts only what it was handed, which is why
     {!Sync_queue} starts without [recover] and neither reads the other's log.
     A process without one accepts writes it will never send.

     What at most one may run is below — reconcile, the poller, the cursor and
     the sweeps all touch the mirror, the bookmark and the cursor, which are
     shared and unarbitrated. *)
  let start_local ?(on_upload_done = fun ~key:_ -> Lwt.return_unit) () =
    let* () = init () in
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_cursor:set_pending_cursor
      ~on_upload_done:(fun ~key ->
        let* () = on_upload_done ~key in
        F.enforce_chunk_cap ());
    Lwt.return_unit

  let start_queue ?(on_upload_done = fun ~key:_ -> Lwt.return_unit) () =
    let* () = start_local ~on_upload_done () in
    Rp.reconcile ()

  (* [freshness] is required, not optional: a frontend that says nothing here
     leaves its users looking at a stale view, and an omitted argument is
     indistinguishable from a considered "nothing to do". *)
  let start ~freshness ?(on_upload_done = fun ~key:_ -> Lwt.return_unit) () =
    let* () = start_queue ~on_upload_done () in
    Sp.start
      ~on_changed:
        (match freshness with Notify f -> f | Revalidates -> fun _ -> ())
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

(* Another process keeps this domain fresh; this one only presents it. *)
module Passive (E : S) : Domain = struct
  include E

  let start ~freshness:_ ?on_upload_done () = E.start_local ?on_upload_done ()
end

(* The process's loops, not a domain's: one Lwt loop however many domains are
   served on it. [serve] calls [ready] once it is serving, which is what lets
   [main_thread] — a presentation whose own loop must hold the main thread, as
   FUSE's mount does — start against something already running. [after] runs on
   the loop's thread once it has finished cleanly. *)
(* An exception escaping [Lwt_main.run] does not stop the process: it leaves one
   with no loop, in which every call blocks on a thread that is gone, and nothing
   reports it until a stop is attempted and hangs — one of these sat silent for
   47 minutes after an SSL read raised inside libev's dispatch, outside any
   promise and so invisible to both [Lwt.catch] and {!Lwt.async_exception_hook}.

   There is nothing to recover to, so the process ends at once and says why.
   [Unix._exit], because at_exit handlers would drain through the loop that just
   died, which is the wedge again. *)
let loop_died exn =
  Log.err "event loop stopped: %s\n%s" (Printexc.to_string exn)
    (Printexc.get_backtrace ());
  flush stdout;
  flush stderr;
  Unix._exit 1

let run ?main_thread ?after serve =
  let lock = Mutex.create () in
  let cond = Condition.create () in
  let ready = ref false in
  let signal_ready () =
    Mutex.lock lock;
    ready := true;
    Condition.broadcast cond;
    Mutex.unlock lock
  in
  let wait_ready () =
    Mutex.lock lock;
    while not !ready do
      Condition.wait cond lock
    done;
    Mutex.unlock lock
  in
  let body () =
    match Lwt_main.run (serve ~ready:signal_ready) with
      | () -> (
          (* A [serve] that returned without ever saying it was ready would
             otherwise leave the main thread waiting on a broadcast from a thread
             that has exited: a hang with nothing logged. *)
          signal_ready ();
          match after with Some f -> f () | None -> ())
      | exception exn -> loop_died exn
  in
  match main_thread with
    | None -> body ()
    | Some main ->
        let t = Thread.create body () in
        wait_ready ();
        main ();
        Thread.join t
