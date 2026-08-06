open Lwt.Syntax
module Ek = Journal.Entry_key

module Make (C : Conf.S) = struct
  module J = Journal.Make (C)
  module Bk = Backends.Make (C)
  module St = Store.Make (C) (Layout.Inode.Make (C))

  let primary = Bk.primary
  let rename_file ~src_key ~dst_key = St.copy_manifest ~src_key ~dst_key
  let head_manifest_opt ~key = St.head_manifest ~key

  (* The one place an entry key becomes a backend key. Concatenating the prefix
     onto a bare entry key skips the month directory and silently misses. *)
  let journal_key entry_key = C.journal_prefix ^ Ek.relative_path entry_key

  let write_journal_entry ?entry_key ops =
    let ek = match entry_key with Some k -> k | None -> J.entry_key () in
    let+ () = Bk.put ~key:(journal_key ek) ~data:(Journal.encode ops) in
    ek

  let bump_cursor entry_key =
    Bk.put ~key:C.cursor_key ~data:(Ek.to_string entry_key)

  (* How far this client has applied the shared journal. Local, because it says
     what *we* have caught up to, not what was published. *)
  let last_sync_file = Filename.concat C.data_dir ("last-sync-" ^ C.domain_name)

  let read_last_sync_key () =
    if Sys.file_exists last_sync_file then (
      try
        let ic = open_in last_sync_file in
        let s = input_line ic in
        close_in ic;
        Ek.of_string (String.trim s)
      with _ -> None)
    else None

  let write_last_sync_key key =
    try
      let oc = open_out last_sync_file in
      output_string oc (Ek.to_string key);
      close_out oc
    with exn ->
      Log.err "file_store: write_last_sync_key: %s" (Printexc.to_string exn)

  let fetch_cursor () =
    let (module Primary : Backend.S) = primary () in
    let+ body = Primary.get_opt ~key:C.cursor_key () in
    Option.bind body (fun b -> Ek.of_string (String.trim b))

  let list_journal_keys ?start_after () =
    let (module Primary : Backend.S) = primary () in
    let+ all = Primary.list_prefix ~prefix:C.journal_prefix () in
    List.filter_map
      (fun (e : Backend.file_entry) ->
        (* Entries sit in month directories ({!Ek.relative_path}); [of_string]
           takes the last segment. *)
          match Ek.of_string e.key with
          | Some ek
            when match start_after with
                   | Some sa -> Ek.compare ek sa > 0
                   | None -> true ->
              Some ek
          | Some _ | None -> None)
      all
    (* Callers apply entries in the order returned, and applying two ops out of
       order diverges local state. Sorted here rather than trusted from the
       backend: a filesystem backend lists in readdir order, which is arbitrary. *)
    |> List.sort Ek.compare

  let get_journal_entry entry_key =
    let (module Primary : Backend.S) = primary () in
    let key = journal_key entry_key in
    Lwt.catch
      (fun () ->
        let+ d = Primary.get ~key () in
        Some (Journal.decode d))
      (fun _ -> Lwt.return_none)

  let journal_entry_published entry_key =
    let (module Primary : Backend.S) = primary () in
    let+ head = Primary.head_opt ~key:(journal_key entry_key) () in
    head <> None
end
