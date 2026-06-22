type t = {
  client : S3_client.t;
  domain_name : string;
  domain_prefix : string;
  chunk_prefix : string;
  trash_prefix : string;
  versioning : bool;
}

let make ~client ~domain_name ~domain_prefix ~chunk_prefix ~trash_prefix
    ~versioning =
  { client; domain_name; domain_prefix; chunk_prefix; trash_prefix; versioning }

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
let domain_name t = t.domain_name
let domain_prefix t = t.domain_prefix
