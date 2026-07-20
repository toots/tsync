open Lwt.Syntax

module Make (C : Conf.S) = struct
  module J = Journal.Make (C)

  let primary () =
    match C.backends with
      | [] -> failwith "no backends configured"
      | b :: _ -> b

  module St = Store.Make (C) (Layout.Inode.Make (C))

  let put_all ~key ~data () =
    Lwt_list.iter_s
      (fun (module B : Backend.S) -> B.put ~key ~data ())
      C.backends

  let rename_file ~src_key ~dst_key = St.copy_manifest ~src_key ~dst_key
  let head_opt ~key = St.head_manifest ~key

  let write_journal_entry ?entry_key ops =
    let ek = match entry_key with Some k -> k | None -> J.entry_key () in
    let key = C.journal_prefix ^ ek in
    let+ () = put_all ~key ~data:(Journal.encode ops) () in
    ek

  let bump_cursor entry_key = put_all ~key:C.cursor_key ~data:entry_key ()

  let fetch_cursor () =
    let (module Primary : Backend.S) = primary () in
    let+ body = Primary.get_opt ~key:C.cursor_key () in
    Option.map String.trim body

  let list_journal_keys ?start_after () =
    let (module Primary : Backend.S) = primary () in
    let+ all = Primary.list_all ~prefix:C.journal_prefix () in
    let prefix_len = String.length C.journal_prefix in
    let sa_base = Option.map Filename.basename start_after in
    List.filter_map
      (fun (e : Backend.file_entry) ->
        let basename =
          if String.length e.key > prefix_len then
            String.sub e.key prefix_len (String.length e.key - prefix_len)
          else e.key
        in
        match sa_base with
          | Some sa when basename <= sa -> None
          | _ -> (
              try
                ignore (Journal.timestamp_ms_of_filename basename);
                Some (basename, Journal.client_uuid_of_filename basename)
              with _ -> None))
      all

  let get_journal_entry entry_key =
    let (module Primary : Backend.S) = primary () in
    let key = C.journal_prefix ^ entry_key in
    Lwt.catch
      (fun () ->
        let+ d = Primary.get ~key () in
        Some (Journal.decode d))
      (fun _ -> Lwt.return_none)
end
