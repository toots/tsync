module Make (C : Conf.S) (F : File.S) = struct
  module Fs = File_store.Make (C)
  module J = Journal.Make (C)

  let last_sync_file = Filename.concat C.data_dir ("last-sync-" ^ C.domain_name)

  let read_last_sync_key () =
    if Sys.file_exists last_sync_file then (
      try
        let ic = open_in last_sync_file in
        let s = input_line ic in
        close_in ic;
        String.trim s
      with _ -> "")
    else ""

  let write_last_sync_key key =
    try
      let oc = open_out last_sync_file in
      output_string oc key;
      close_out oc
    with exn ->
      Log.err "sync_poller: write_last_sync_key: %s" (Printexc.to_string exn)

  let op_key op =
    match op with
      | `Put (rel, _) | `Delete rel | `Mkdir rel | `Rmdir rel ->
          C.domain_prefix ^ rel
      | `Rename { Journal.dst; _ } -> C.domain_prefix ^ dst

  let do_sync ~on_changed ~my_uuid () =
    let last_key = read_last_sync_key () in
    let last_basename =
      if last_key = "" then "" else Filename.basename last_key
    in
    let all_keys = Fs.list_journal_keys () in
    all_keys
    |> List.filter (fun (k, _) -> last_basename = "" || k > last_basename)
    |> List.filter (fun (_, uuid) -> uuid <> my_uuid)
    |> List.iter (fun (ek, _) ->
        match Fs.get_journal_entry ek with
          | None -> ()
          | Some ops ->
              F.apply_foreign_ops ops;
              List.iter (fun op -> on_changed (op_key op)) ops);
    match List.rev all_keys with
      | [] -> ()
      | (k, _) :: _ -> write_last_sync_key (C.journal_prefix ^ k)

  let sync_once () =
    do_sync ~on_changed:(fun _ -> ()) ~my_uuid:(J.client_uuid ()) ()

  let start ?(on_changed = fun _ -> ()) () =
    let my_uuid = J.client_uuid () in
    ignore
      (Thread.create
         (fun () ->
           let last_version = ref "" in
           while true do
             Unix.sleepf 2.0;
             try
               match Fs.fetch_version () with
                 | None -> ()
                 | Some v when v = !last_version -> ()
                 | Some v ->
                     last_version := v;
                     do_sync ~on_changed ~my_uuid ()
             with exn -> Log.err "sync_poller: %s" (Printexc.to_string exn)
           done)
         ())
end
