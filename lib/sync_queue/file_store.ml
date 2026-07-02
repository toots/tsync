module Make (C : Conf.S) = struct
  module J = Journal.Make (C)

  let primary () =
    match C.backends with
      | [] -> failwith "no backends configured"
      | b :: _ -> b

  let put_all ~key ~data () =
    List.iter (fun (module B : Backend.S) -> B.put ~key ~data ()) C.backends

  let delete_dir ~prefix =
    let (module Primary : Backend.S) = primary () in
    let keys =
      List.map (fun e -> e.Backend.key) (Primary.list_all ~prefix ())
    in
    List.iter (fun (module B : Backend.S) -> B.delete_multi keys) C.backends

  let create_directory ~key = put_all ~key ~data:"" ()

  let rename_file ~src_key ~dst_key =
    List.iter
      (fun (module B : Backend.S) ->
        B.copy ~src_key ~dst_key ();
        B.delete ~key:src_key ())
      C.backends

  let rename_directory ~src_prefix ~dst_prefix =
    let (module Primary : Backend.S) = primary () in
    let all = Primary.list_all ~prefix:src_prefix () in
    let src_len = String.length src_prefix in
    List.iter
      (fun (e : Backend.file_entry) ->
        let suffix = String.sub e.key src_len (String.length e.key - src_len) in
        let dst_key = dst_prefix ^ suffix in
        List.iter
          (fun (module B : Backend.S) -> B.copy ~src_key:e.key ~dst_key ())
          C.backends)
      all;
    let keys = List.map (fun e -> e.Backend.key) all in
    List.iter (fun (module B : Backend.S) -> B.delete_multi keys) C.backends

  let list_directory ~prefix =
    let (module Primary : Backend.S) = primary () in
    Primary.list_directory ~prefix ()

  let list_all_files ~prefix =
    let (module Primary : Backend.S) = primary () in
    Primary.list_all ~prefix ()

  let head_opt ~key =
    let (module Primary : Backend.S) = primary () in
    Primary.head_opt ~key ()

  let write_journal_entry ?entry_key ops =
    let ek = match entry_key with Some k -> k | None -> J.entry_key () in
    let key = C.journal_prefix ^ ek in
    put_all ~key ~data:(Journal.encode ops) ();
    ek

  let bump_cursor entry_key = put_all ~key:C.cursor_key ~data:entry_key ()

  let fetch_cursor () =
    let (module Primary : Backend.S) = primary () in
    match Primary.head_opt ~key:C.cursor_key () with
      | None -> None
      | Some _ -> Some (String.trim (Primary.get ~key:C.cursor_key ()))

  let list_journal_keys ?start_after () =
    let (module Primary : Backend.S) = primary () in
    let all = Primary.list_all ~prefix:C.journal_prefix () in
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
    try Some (Journal.decode (Primary.get ~key ())) with _ -> None
end
