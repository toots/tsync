module Make(C : Conf.S) = struct
  module J = Journal.Make(C)

  let delete_dir ~prefix =
    let all = S3_client.list_all C.client ~prefix () in
    S3_client.delete_multi C.client (List.map (fun e -> e.S3_client.key) all)

  let create_directory ~key =
    S3_client.put C.client ~content_type:"application/x-directory" ~key ~data:"" ()

  let rename_file ~src_key ~dst_key =
    S3_client.copy C.client ~src_key ~dst_key ();
    S3_client.delete C.client ~key:src_key ()

  let rename_directory ~src_prefix ~dst_prefix =
    let all = S3_client.list_all C.client ~prefix:src_prefix () in
    let src_len = String.length src_prefix in
    List.iter
      (fun e ->
        let suffix =
          String.sub e.S3_client.key src_len
            (String.length e.S3_client.key - src_len)
        in
        S3_client.copy C.client ~src_key:e.S3_client.key
          ~dst_key:(dst_prefix ^ suffix) ())
      all;
    S3_client.delete_multi C.client (List.map (fun e -> e.S3_client.key) all)

  let list_directory ~prefix = S3_client.list_directory C.client ~prefix ()
  let list_all_files ~prefix = S3_client.list_all C.client ~prefix ()
  let head_opt ~key = S3_client.head_opt C.client ~key ()

  let write_journal_entry ?entry_key ops =
    let ek = match entry_key with Some k -> k | None -> J.entry_key () in
    let key = C.journal_prefix ^ ek in
    S3_client.put C.client ~content_type:"application/x-ndjson" ~key
      ~data:(Journal.encode ops) ();
    ek

  let bump_version entry_key =
    S3_client.put C.client ~key:C.version_key ~data:entry_key ()

  let fetch_version () =
    match S3_client.head_opt C.client ~key:C.version_key () with
      | None -> None
      | Some _ ->
          Some (String.trim (S3_client.get C.client ~key:C.version_key ()))

  let list_journal_keys ?start_after () =
    let all = S3_client.list_all C.client ~prefix:C.journal_prefix () in
    let prefix_len = String.length C.journal_prefix in
    let sa_base = Option.map Filename.basename start_after in
    List.filter_map
      (fun (e : S3_client.file_entry) ->
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
    let key = C.journal_prefix ^ entry_key in
    try Some (Journal.decode (S3_client.get C.client ~key ())) with _ -> None
end
