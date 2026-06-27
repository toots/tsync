type t = {
  client : S3_client.t;
  domain_name : string;
  domain_prefix : string;
  chunk_prefix : string;
  trash_prefix : string;
  versioning : bool;
  journal_prefix : string;
  version_key : string;
}

let make ~client ~domain_name ~domain_prefix ~chunk_prefix ~trash_prefix
    ~versioning ~journal_prefix ~version_key =
  {
    client;
    domain_name;
    domain_prefix;
    chunk_prefix;
    trash_prefix;
    versioning;
    journal_prefix;
    version_key;
  }

let upload t ~key ~src_path =
  S3_client.put_chunked t.client ~key ~src_path ~chunk_prefix:t.chunk_prefix

let download t ~key ~dst_path =
  Cache.ensure_parent_dir dst_path;
  S3_client.get_chunked t.client ~key ~dst_path ~chunk_prefix:t.chunk_prefix

let delete_file t ~key =
  if t.versioning then begin
    let trash_key =
      Versioning.trash_key ~s3_key:key ~domain_prefix:t.domain_prefix
        ~trash_prefix:t.trash_prefix
    in
    S3_client.copy t.client ~src_key:key ~dst_key:trash_key ()
  end;
  S3_client.delete t.client ~key ()

(* Delete a directory recursively without versioning (directory markers are not trashed) *)
let delete_dir t ~prefix =
  let all = S3_client.list_all t.client ~prefix () in
  let keys = List.map (fun e -> e.S3_client.key) all in
  S3_client.delete_multi t.client keys

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
let head_opt t ~key = S3_client.head_opt t.client ~key ()

(* Like head_opt but returns the real file size for chunked manifests *)
let stat_file t ~key =
  match S3_client.head_opt t.client ~key () with
    | None -> None
    | Some c when c.S3_client.content_type = Some Chunk_manifest.content_type ->
        (try
           let m = Chunk_manifest.of_string (S3_client.get t.client ~key ()) in
           Some { c with S3_client.size = Int64.to_int m.size }
         with _ -> Some c)
    | Some c -> Some c
let domain_name t = t.domain_name
let domain_prefix t = t.domain_prefix
let journal_prefix t = t.journal_prefix

(* ── Journal ─────────────────────────────────────────────────────────────── *)

(* Write journal entry to S3 only; returns the entry key used.
   The version key is NOT updated — call bump_version separately. *)
let write_journal_entry ?entry_key ops t =
  let ek = match entry_key with Some k -> k | None -> Journal.entry_key () in
  let key = t.journal_prefix ^ ek in
  S3_client.put t.client ~content_type:"application/x-ndjson" ~key
    ~data:(Journal.encode ops) ();
  ek

(* Update the version key to point to a given entry key. *)
let bump_version t entry_key =
  S3_client.put t.client ~key:t.version_key ~data:entry_key ()

(* Write journal entry then bump version. Used for crash recovery only, not the hot path. *)
let write_journal ?entry_key ops t =
  let ek = match entry_key with Some k -> k | None -> Journal.entry_key () in
  ignore (write_journal_entry ~entry_key:ek ops t);
  bump_version t ek

let fetch_version t =
  match S3_client.head_opt t.client ~key:t.version_key () with
    | None -> None
    | Some _ ->
        Some (String.trim (S3_client.get t.client ~key:t.version_key ()))

(* Returns (entry_key_basename, client_uuid) list, optionally filtered by start_after.
   start_after may be a bare basename or a full S3 key (Filename.basename is applied). *)
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
  try Some (Journal.decode (S3_client.get t.client ~key ()))
  with _ -> None

(* Replay locally-pending WAL entries that didn't make it to S3 before crash *)
let recover_pending_ops t =
  let my_uuid = Journal.client_uuid () in
  List.iter
    (fun (entry_key, ops) ->
      let remote_key = t.journal_prefix ^ entry_key in
      if S3_client.head_opt t.client ~key:remote_key () <> None then
        (* already made it to S3 before crash *)
        Journal.delete_local_pending ~entry_key
      else begin
        let newer_keys = list_journal_keys ~start_after:entry_key t () in
        let remotely_modified = Hashtbl.create 16 in
        List.iter
          (fun (ek, uuid) ->
            if uuid <> my_uuid then
              match get_journal_entry t ek with
                | None -> ()
                | Some remote_ops ->
                    List.iter
                      (fun op ->
                        match op with
                          | `Put (k, _) | `Delete k | `Mkdir k | `Rmdir k ->
                              Hashtbl.replace remotely_modified k ()
                          | `Rename (k, src, _) ->
                              Hashtbl.replace remotely_modified k ();
                              Hashtbl.replace remotely_modified src ())
                      remote_ops)
          newer_keys;
        let replayed =
          List.filter
            (fun op ->
              let k =
                match op with
                  | `Put (k, _) | `Delete k | `Mkdir k | `Rmdir k -> k
                  | `Rename (k, _, _) -> k
              in
              not (Hashtbl.mem remotely_modified k))
            ops
        in
        List.iter
          (fun op ->
            try
              match op with
                | `Put (rel_key, _) ->
                    let full_key = t.domain_prefix ^ rel_key in
                    let cache_path =
                      Cache.cache_path ~domain_name:t.domain_name
                        ~domain_prefix:t.domain_prefix full_key
                    in
                    if Sys.file_exists cache_path then
                      ignore (upload t ~key:full_key ~src_path:cache_path)
                | `Delete rel_key ->
                    delete_file t ~key:(t.domain_prefix ^ rel_key)
                | `Mkdir rel_key ->
                    create_directory t ~key:(t.domain_prefix ^ rel_key)
                | `Rmdir rel_key ->
                    delete_dir t ~prefix:(t.domain_prefix ^ rel_key)
                | `Rename (dst_rel, src_rel, _) ->
                    let src_key = t.domain_prefix ^ src_rel in
                    let dst_key = t.domain_prefix ^ dst_rel in
                    (match
                       S3_client.head_opt t.client ~key:(src_key ^ "/") ()
                     with
                      | Some _ ->
                          rename_directory t ~src_prefix:(src_key ^ "/")
                            ~dst_prefix:(dst_key ^ "/")
                      | None -> rename_file t ~src_key ~dst_key)
            with exn ->
              Log.err "recover_pending_ops: %s" (Printexc.to_string exn))
          replayed;
        if replayed <> [] then write_journal ~entry_key replayed t;
        Journal.delete_local_pending ~entry_key
      end)
    (Journal.local_pending_entries ~uuid:my_uuid)
