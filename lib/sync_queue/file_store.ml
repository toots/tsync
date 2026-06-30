open Conf

type t = Conf.t

let make (conf : Conf.t) : t = conf
let domain_name t = t.domain_name
let domain_prefix t = t.domain_prefix
let journal_prefix t = t.journal_prefix
let client t = t.client
let chunk_prefix t = t.chunk_prefix
let trash_prefix t = t.trash_prefix
let versioning t = t.versioning
let cache_root t = t.cache_root
let socket_path t = t.socket_path
let notify_path t = t.notify_path

(* ── Directory operations ─────────────────────────────────────────────────── *)

let delete_dir t ~prefix =
  let all = S3_client.list_all t.client ~prefix () in
  S3_client.delete_multi t.client (List.map (fun e -> e.S3_client.key) all)

let create_directory t ~key =
  S3_client.put t.client ~content_type:"application/x-directory" ~key ~data:""
    ()

let rename_file t ~src_key ~dst_key =
  S3_client.copy t.client ~src_key ~dst_key ();
  S3_client.delete t.client ~key:src_key ()

let rename_directory t ~src_prefix ~dst_prefix =
  let all = S3_client.list_all t.client ~prefix:src_prefix () in
  let src_len = String.length src_prefix in
  List.iter
    (fun e ->
      let suffix =
        String.sub e.S3_client.key src_len
          (String.length e.S3_client.key - src_len)
      in
      S3_client.copy t.client ~src_key:e.S3_client.key
        ~dst_key:(dst_prefix ^ suffix) ())
    all;
  S3_client.delete_multi t.client (List.map (fun e -> e.S3_client.key) all)

let list_directory t ~prefix = S3_client.list_directory t.client ~prefix ()
let list_all_files t ~prefix = S3_client.list_all t.client ~prefix ()
let head_opt t ~key = S3_client.head_opt t.client ~key ()

(* ── Journal ─────────────────────────────────────────────────────────────── *)

let write_journal_entry ?entry_key ops t =
  let ek = match entry_key with Some k -> k | None -> Journal.entry_key () in
  let key = t.journal_prefix ^ ek in
  S3_client.put t.client ~content_type:"application/x-ndjson" ~key
    ~data:(Journal.encode ops) ();
  ek

let bump_version t entry_key =
  S3_client.put t.client ~key:t.version_key ~data:entry_key ()

let write_journal ?entry_key ops t =
  let ek = match entry_key with Some k -> k | None -> Journal.entry_key () in
  ignore (write_journal_entry ~entry_key:ek ops t);
  bump_version t ek

let fetch_version t =
  match S3_client.head_opt t.client ~key:t.version_key () with
    | None -> None
    | Some _ ->
        Some (String.trim (S3_client.get t.client ~key:t.version_key ()))

let list_journal_keys ?start_after t () =
  let all = S3_client.list_all t.client ~prefix:t.journal_prefix () in
  let prefix_len = String.length t.journal_prefix in
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

let get_journal_entry t entry_key =
  let key = t.journal_prefix ^ entry_key in
  try Some (Journal.decode (S3_client.get t.client ~key ())) with _ -> None
