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

  (* The high-water mark only advances past entries that applied cleanly. A
     failure aborts the pass and the entry is retried on the next poll, rather
     than being skipped and diverging local state until a full resync. *)
  let do_sync ~on_changed ~my_uuid () =
    let* all_keys =
      Fs.list_journal_keys ?start_after:(read_last_sync_key ()) ()
    in
    all_keys
    |> Lwt_list.iter_s (fun ek ->
        let* () =
          if Journal.Entry_key.client_uuid ek = my_uuid then Lwt.return_unit
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
                      let* () = do_sync ~on_changed ~my_uuid () in
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
