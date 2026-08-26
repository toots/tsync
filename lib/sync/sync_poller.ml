open Lwt.Syntax

(* The timer, not the algorithm: applying foreign entries is {!Replay}, which
   [tsync sync] calls too. This only decides when to look. *)
module Make (C : Conf.S) (F : File_ops.S with type 'a io := 'a Lwt.t) = struct
  module Fs = File_store.Make (C)
  module Rp = Replay.Make (C) (F)

  let last_version = ref None

  let same v =
    match !last_version with
      | Some prev -> Journal.Entry_key.compare prev v = 0
      | None -> false

  (* The cursor first, and only then the journal. A peer publishes an entry and
     bumps the cursor after it; reading the journal on every tick regardless
     would cost a listing per client per interval for the state that says
     nothing has changed. It also means an entry whose bump never landed is one
     nobody comes looking for. *)
  let sync_once ~on_changed () =
    let* cursor = Fs.fetch_cursor () in
    match cursor with
      | None -> Lwt.return 0
      | Some v when same v -> Lwt.return 0
      | Some v ->
          (* Recorded only after a clean pass, so a failed one is retried on the
             next tick. *)
          let* n = Rp.apply_foreign ~on_changed () in
          last_version := Some v;
          Lwt.return n

  let start ~on_changed () =
    Lwt.async (fun () ->
        let rec loop () =
          let* () = Lwt_unix.sleep 2.0 in
          let* () =
            Lwt.catch
              (fun () ->
                let+ (_ : int) = sync_once ~on_changed () in
                ())
              (fun exn ->
                Log.err "sync_poller: %s" (Printexc.to_string exn);
                Lwt.return_unit)
          in
          loop ()
        in
        loop ())
end
