open Lwt.Syntax

module Make (C : Conf.S) = struct
  module J = Journal.Make (C)
  module Bk = Backends.Make (C)
  module St = Store.Make (C) (Layout.Inode.Make (C))

  let primary = Bk.primary
  let rename_file ~src_key ~dst_key = St.copy_manifest ~src_key ~dst_key
  let head_manifest_opt ~key = St.head_manifest ~key

  (* The one place an entry key becomes a backend key. Concatenating the prefix
     onto a bare entry key skips the month directory and silently misses. *)
  let journal_key entry_key = C.journal_prefix ^ Journal.relative_path entry_key

  let write_journal_entry ?entry_key ops =
    let ek = match entry_key with Some k -> k | None -> J.entry_key () in
    let+ () = Bk.put ~key:(journal_key ek) ~data:(Journal.encode ops) in
    ek

  let bump_cursor entry_key = Bk.put ~key:C.cursor_key ~data:entry_key

  (* How far this client has applied the shared journal. Local, because it says
     what *we* have caught up to, not what was published. *)
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
      Log.err "file_store: write_last_sync_key: %s" (Printexc.to_string exn)

  let fetch_cursor () =
    let (module Primary : Backend.S) = primary () in
    let+ body = Primary.get_opt ~key:C.cursor_key () in
    Option.map String.trim body

  let list_journal_keys ?start_after () =
    let (module Primary : Backend.S) = primary () in
    let+ all = Primary.list_prefix ~prefix:C.journal_prefix () in
    let sa_base = Option.map Filename.basename start_after in
    List.filter_map
      (fun (e : Backend.file_entry) ->
        (* Entries sit in month directories ({!Journal.relative_path}); the entry
           key is the last segment, and comparing those still orders the journal
           chronologically. *)
        let basename = Filename.basename e.key in
        match sa_base with
          | Some sa when basename <= sa -> None
          | _ -> (
              try
                ignore (Journal.timestamp_ms_of_filename basename);
                Some (basename, Journal.client_uuid_of_filename basename)
              with _ -> None))
      all
    (* Callers apply entries in the order returned, and applying two ops out of
       order diverges local state. Sorted here rather than trusted from the
       backend: a filesystem backend lists in readdir order, which is arbitrary. *)
    |> List.sort (fun (a, _) (b, _) -> compare a b)

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
