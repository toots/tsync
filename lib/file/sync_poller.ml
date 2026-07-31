open Lwt.Syntax

module Make (C : Conf.S) (F : File.S) = struct
  module Fs = File_store.Make (C)
  module J = Journal.Make (C)

  let read_last_sync_key = Fs.read_last_sync_key
  let write_last_sync_key = Fs.write_last_sync_key

  let op_key op =
    match op with
      | `Put (rel, _) | `Delete rel | `Mkdir (rel, _) | `Rmdir (rel, _) ->
          C.domain_prefix ^ rel
      | `Rename { Journal.dst; _ } -> C.domain_prefix ^ dst

  (* Apply foreign entries in order, advancing the high-water mark only past
     entries that applied cleanly. A failure (e.g. a transient backend error
     fetching a manifest) aborts the pass; the failed entry is retried on the
     next poll instead of being silently skipped, which would diverge local
     state until a full resync. *)
  let do_sync ~on_changed ~my_uuid () =
    let last_key = read_last_sync_key () in
    let last_basename =
      if last_key = "" then "" else Filename.basename last_key
    in
    let* all_keys = Fs.list_journal_keys () in
    all_keys
    |> List.filter (fun (k, _) -> last_basename = "" || k > last_basename)
    |> Lwt_list.iter_s (fun (ek, uuid) ->
        let* () =
          if uuid = my_uuid then Lwt.return_unit
          else
            let* entry = Fs.get_journal_entry ek in
            match entry with
              | None -> Lwt.return_unit
              | Some ops ->
                  let* () = F.apply_foreign_ops ops in
                  List.iter (fun op -> on_changed (op_key op)) ops;
                  Lwt.return_unit
        in
        write_last_sync_key ek;
        Lwt.return_unit)

  let sync_once () =
    do_sync ~on_changed:(fun _ -> ()) ~my_uuid:(J.client_uuid ()) ()

  let start ?(on_changed = fun _ -> ()) () =
    let my_uuid = J.client_uuid () in
    Lwt.async (fun () ->
        let last_version = ref "" in
        let rec loop () =
          let* () = Lwt_unix.sleep 2.0 in
          let* () =
            Lwt.catch
              (fun () ->
                let* cursor = Fs.fetch_cursor () in
                match cursor with
                  | None -> Lwt.return_unit
                  | Some v when v = !last_version -> Lwt.return_unit
                  | Some v ->
                      (* Record the cursor only after a clean pass, so a
                         failed pass is retried on the next tick. *)
                      let* () = do_sync ~on_changed ~my_uuid () in
                      last_version := v;
                      Lwt.return_unit)
              (fun exn ->
                Log.err "sync_poller: %s" (Printexc.to_string exn);
                Lwt.return_unit)
          in
          loop ()
        in
        loop ())
end
