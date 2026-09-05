(* When to look, not what to do about it: applying foreign entries is
   {!Replay}, which [tsync sync] calls too. Even the when is mostly the store's,
   which says how long a wait for its cursor is worth. *)

module Over
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Js : File_store.OVER with type 'a io := 'a Io.t)
    (Rp : sig
      module Make
          (_ : Conf.S with type 'a io = 'a Io.t)
          (_ : File_ops.S with type 'a io := 'a Io.t) : sig
        val apply_foreign : on_changed:(string -> unit) -> unit -> int Io.t
      end
    end) =
struct
  open Io_syntax.Make (Io)

  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (F : File_ops.S with type 'a io := 'a Io.t) =
  struct
    module Js = Js.Make (C)
    module Rp = Rp.Make (C) (F)

    let last_version = ref None
    let last_swept = ref 0.

    let same v =
      match !last_version with
        | Some prev -> Journal.Entry_key.compare prev v = 0
        | None -> false

    (* How long a peer's change may go unseen when its cursor bump never lands
       or lands behind a later one from another of its processes. Timed from the
       last listing rather than from a wait that outran a timeout: every store
       answers a wait well inside this — a peer holds a watch for at most
       {!Http_proxy.Watch.max_seconds}, an object store sleeps a couple of
       seconds — so a sweep raced against the wait is one that never runs.

       ponytail: one listing per client per minute while nothing changes; an
       hour or a jittered interval if a fleet of idle clients ever shows up in a
       store's request bill. *)
    let sweep_interval = ref 60.
    let set_sweep_interval s = sweep_interval := s

    (* The cursor first, and only then the journal. A peer publishes an entry and
       bumps the cursor after it; reading the journal on every tick regardless
       would cost a listing per client per interval for the state that says
       nothing has changed. An entry whose bump never landed is one only the
       sweep goes looking for. *)
    let sync_once ~on_changed () =
      let* cursor = Js.fetch_cursor () in
      let moved = match cursor with None -> false | Some v -> not (same v) in
      let due = Unix.gettimeofday () -. !last_swept >= !sweep_interval in
      if not (moved || due) then Io.return 0
      else begin
        last_swept := Unix.gettimeofday ();
        (* Recorded only after a clean pass, so a failed one is retried on the
           next tick. *)
        let* n = Rp.apply_foreign ~on_changed () in
        Option.iter (fun v -> last_version := Some v) cursor;
        Io.return n
      end

    (* Only ever reached by a failure. The wait is what paces this loop, so
       something that fails without taking any time would otherwise spin. *)
    let retry_floor = 2.

    let start ~on_changed () =
      Io.async (fun () ->
          let step () =
            (* A ceiling on the wait, not what times the sweep: a store that
               answers none at all must not park this loop for good. *)
            let* () =
              Io.catch
                (fun () ->
                  Clock.with_timeout !sweep_interval (fun () ->
                      Js.wait_cursor_change !last_version))
                (fun exn ->
                  if Clock.is_timeout exn then Io.return () else Io.fail exn)
            in
            let+ (_ : int) = sync_once ~on_changed () in
            ()
          in
          let rec loop () =
            let* () =
              Io.catch step (fun exn ->
                  Log.err "sync_poller: %s" (Printexc.to_string exn);
                  Clock.sleep retry_floor)
            in
            loop ()
          in
          loop ())
  end
end
