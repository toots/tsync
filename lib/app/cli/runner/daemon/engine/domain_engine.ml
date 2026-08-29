open Lwt.Syntax

(* What a frontend is given for one domain: its file operations, the request
   handler built over them, and the queue that sends what it accepts.

   Every process serving the domain gets the same thing, so there is nothing
   here to ask about and no way to hold a lesser one. Keeping the domain
   converging with the store is {!Converging}, and it runs somewhere else. *)
module type Domain = sig
  module F : File_ops.S with type 'a io := 'a Lwt.t
  module Ih : Ipc_handler.S

  val start :
    ?on_upload_done:(key:Logical_key.t -> unit Lwt.t) -> unit -> unit Lwt.t

  val drain : unit -> unit Lwt.t
  val stats_fields : unit -> (string * Yojson.Safe.t) list
end

(* The work a domain needs done once per machine, whoever is presenting it.

   Reconcile, the poller and the sweeps write the mirror, the applied-through
   bookmark and the staged tree, which are shared between every process serving
   the domain and arbitrated between none of them. [on_changed] is how what the
   poller applied reaches the frontends, which are elsewhere and have no other
   way to hear it. *)
module type Converging = sig
  val recover : unit -> unit Lwt.t
  val start : on_changed:(string -> unit) -> unit -> unit Lwt.t
  val drain : unit -> unit Lwt.t
  val stats_fields : unit -> (string * Yojson.Safe.t) list
end

module type S = sig
  include Domain

  val init : unit -> unit Lwt.t
  val recover : unit -> unit Lwt.t

  (* Presenting, plus the records this client left behind. For a one-shot
     command, which is alone and so owes both. *)
  val start_queue :
    ?on_upload_done:(key:Logical_key.t -> unit Lwt.t) -> unit -> unit Lwt.t

  val converge : on_changed:(string -> unit) -> unit -> unit Lwt.t
end

(* The tree decides what an absent entry means, so it is the caller's to choose;
   the checkout root below is the same either way. *)
module Make_over
    (Ck : File_lwt.TREE with type 'a io := 'a Lwt.t)
    (C : Conf_lwt.S) : S = struct
  module Lk = Logical_key.Make (C)
  module F = File_lwt.Make_over (Ck) (C)
  module Sq = Sync_lwt.Sync_queue.Make (C) (F)
  module Ih = Ipc_handler.Make (C) (F) (Sq)
  module Sp = Sync_lwt.Sync_poller.Make (C) (F)
  module Rp = Sync_lwt.Replay.Make (C) (F)
  module Mf = Checkout_lwt.Make (C)
  module Mfs = Staged_lwt.Manifest.Make (C)
  module Fs = File_store_lwt.Make (C)

  (* Also nudged after each upload, but downloads grow the store too. The same
     sweep looks for deferred work a one-shot command left behind, which is
     bounded by how long that work may sit rather than by the store's growth. *)
  let housekeeping_interval = 60.

  (* The manifest tree, which a caller needs before it can resolve a key at all.
     Separate from {!start_queue} because a read-only command needs this and
     nothing else. *)
  let init () = Mf.ensure_root ()

  (* Apart from {!init}, which every process calls: both of these name a
     leftover by an absence a live write also produces. *)
  let recover () =
    let* () = Mf.reap_leftovers () in
    F.reclaim_staged_orphans ()

  (* Every process serving this domain runs its own upload queue: the workers
     are in-memory and each posts only what it was handed, which is why
     {!Sync_queue} starts without [recover] and neither reads the other's log.
     A process without one accepts writes it will never send.

     The bumps those uploads owe are {!File_store}'s to coalesce and publish;
     what this owes is the flush in {!drain}, so an entry uploaded here is one
     a peer goes looking for rather than one it never hears about. *)
  let start ?(on_upload_done = fun ~key:_ -> Lwt.return_unit) () =
    let* () = init () in
    Sq.start ~on_upload_done:(fun ~key ->
        let* () = on_upload_done ~key in
        F.enforce_chunk_cap ());
    Lwt.return_unit

  (* The queue must be running first: recovery goes through it, for the journal
     entry and cursor bump an upload owes. *)
  let start_queue ?(on_upload_done = fun ~key:_ -> Lwt.return_unit) () =
    let* () = start ~on_upload_done () in
    Rp.reconcile ()

  let converge ~on_changed () =
    let* () = start_queue () in
    Sp.start ~on_changed ();
    Lwt.async (fun () ->
        let sweep what f =
          Lwt.catch f (fun exn ->
              Log.err "%s: %s" what (Printexc.to_string exn);
              Lwt.return_unit)
        in
        let rec loop () =
          let* () = Lwt_unix.sleep housekeeping_interval in
          let* () = sweep "chunk cap sweep" F.enforce_chunk_cap in
          let* () = sweep "deferred rescan" Durable_queue_lwt.rescan_all in
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
    let* () = Fs.flush_cursor () in
    Backend_lwt.drain ()

  let stats_fields () =
    [
      ("pendingUploads", `Int (Sq.pending ()));
      ("uploadsCompleted", `Int (Sq.completed_count ()));
    ]
end

module Make (C : Conf_lwt.S) : S = Make_over (Checkout_lwt) (C)

(* The convergence half of an engine, for a caller holding several domains and
   presenting none of them. *)
module Converge (E : S) : Converging = struct
  let recover = E.recover
  let start = E.converge
  let drain = E.drain
  let stats_fields = E.stats_fields
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

let handshake () =
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
  (signal_ready, wait_ready)

(* Carries the backtrace of a raise across [on_loop], which re-raises on the
   calling thread and so replaces the backtrace of what actually failed with its
   own line. The exception value is the only thing that crosses. *)
exception With_backtrace of exn * Printexc.raw_backtrace

(* A handler arriving on a thread of the platform's own -- a libfuse worker, a
   JVM binder thread -- runs its file operations on the single Lwt loop and
   blocks only itself meanwhile. *)
let on_loop f =
  Lwt_preemptive.run_in_main (fun () ->
      Lwt.catch f (function
        (* Matched before the capture rather than after: a [Unix_error] is an
           answer rather than a failure and wants no backtrace, matching cannot
           raise, and [getattr] answering ENOENT is the hot path. *)
        | Unix.Unix_error _ as exn -> Lwt.fail exn
        | exn ->
            let backtrace = Printexc.get_raw_backtrace () in
            Lwt.fail (With_backtrace (exn, backtrace))))

(* The loop on a thread of its own, for a host process whose main thread belongs
   to a platform rather than to us. Nothing joins it: it ends with the process,
   and the absence of a stop is what keeps [on_loop] from waiting on a loop that
   has finished. *)
let start_detached serve =
  let signal_ready, wait_ready = handshake () in
  let body () =
    match Lwt_main.run (serve ~ready:signal_ready) with
      | () -> signal_ready ()
      | exception exn -> loop_died exn
  in
  ignore (Thread.create body ());
  wait_ready ()

let run ?main_thread ?after serve =
  let signal_ready, wait_ready = handshake () in
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
