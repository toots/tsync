open Lwt.Syntax

(* The timer, not the algorithm: applying foreign entries is {!Replay}, which
   [tsync sync] calls too. This only decides when to look. *)
module Make (C : Conf.S) (F : File.S) = struct
  module Fs = File_store.Make (C)
  module Rp = Replay.Make (C) (F)

  let sync_once () =
    let+ (_ : int) = Rp.apply_foreign () in
    ()

  let start ?(on_changed = fun _ -> ()) () =
    Lwt.async (fun () ->
        let last_version = ref None in
        let same v =
          match !last_version with
            | Some prev -> Journal.Entry_key.compare prev v = 0
            | None -> false
        in
        let rec loop () =
          let* () = Lwt_unix.sleep 2.0 in
          let* () =
            Lwt.catch
              (fun () ->
                let* cursor = Fs.fetch_cursor () in
                match cursor with
                  | None -> Lwt.return_unit
                  | Some v when same v -> Lwt.return_unit
                  | Some v ->
                      (* Only after a clean pass, so a failed one is retried on
                         the next tick. *)
                      let* (_ : int) = Rp.apply_foreign ~on_changed () in
                      last_version := Some v;
                      Lwt.return_unit)
              (fun exn ->
                Log.err "sync_poller: %s" (Printexc.to_string exn);
                Lwt.return_unit)
          in
          loop ()
        in
        loop ())
end
