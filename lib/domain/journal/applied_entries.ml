open Lwt.Syntax

let suffix = ".log"

let dir ~cache_root ~domain_name =
  Cache_layout.applied_dir ~cache_root domain_name

(* ["<YYYY-MM>/<entry key>"] is what the published journal files an entry under,
   so the shard an entry belongs to is read from there rather than spelled a
   second time here. *)
let shard entry_key =
  let rel = Journal.Entry_key.relative_path entry_key in
  match String.index_opt rel '/' with
    | Some i -> String.sub rel 0 i
    | None -> rel

let shard_path ~cache_root ~domain_name entry_key =
  Filename.concat (dir ~cache_root ~domain_name) (shard entry_key ^ suffix)

(* Newline first, not last. A writer torn mid-record leaves no terminator, and a
   record that ended with one would then be glued onto the front of the next —
   which parses, as a key nothing wrote. Leading it instead means the next
   append closes the torn record, and only the torn record is lost. *)
let encode entry_key ops =
  "\n"
  ^ Journal.Entry_key.to_string entry_key
  ^ "\t"
  ^ Yojson.Basic.to_string (`List (List.map Journal.to_json ops))

(* Total: a line this cannot read is one a writer tore, and dropping it is what
   lets the reader carry on past it. *)
let decode line =
  match String.index_opt line '\t' with
    | None -> None
    | Some i -> (
        let key = String.sub line 0 i in
        let body = String.sub line (i + 1) (String.length line - i - 1) in
        match Journal.Entry_key.of_string key with
          | None -> None
          | Some entry_key -> (
              match Yojson.Basic.from_string body with
                | `List l -> Some (entry_key, List.filter_map Journal.of_json l)
                | _ | (exception _) -> None))

let rec write_all fd s off =
  if off >= String.length s then Lwt.return_unit
  else
    let* n = Lwt_unix.write_string fd s off (String.length s - off) in
    if n <= 0 then Lwt.fail (Failure "applied entries: short write")
    else write_all fd s (off + n)

let note ~cache_root ~domain_name entry_key ops =
  let* () = Io_lwt.Fs.mkdir_p (dir ~cache_root ~domain_name) in
  let path = shard_path ~cache_root ~domain_name entry_key in
  let* fd =
    Lwt_unix.openfile path [Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT] 0o600
  in
  Lwt.finalize
    (fun () -> write_all fd (encode entry_key ops) 0)
    (fun () -> Lwt_unix.close fd)

(* Ascending, which for ["YYYY-MM.log"] is chronological. *)
let shards ~cache_root ~domain_name =
  let+ names = Io_lwt.Fs.readdir_list_quiet (dir ~cache_root ~domain_name) in
  List.sort compare
    (List.filter (fun n -> Filename.check_suffix n suffix) names)

let read_shard ~cache_root ~domain_name name =
  let+ body =
    Io_lwt.Fs.read_file_opt
      (Filename.concat (dir ~cache_root ~domain_name) name)
  in
  match body with
    | None -> []
    | Some body -> List.filter_map decode (String.split_on_char '\n' body)

type page = {
  entries : (Journal.Entry_key.t * Journal.op list) list;
  more : bool;
}

let since ~cache_root ~domain_name ?since ~limit () =
  let* names = shards ~cache_root ~domain_name in
  (* A shard before the anchor's own holds nothing after it, so it is not read.
     The anchor's is, since it holds entries on both sides of it. *)
  let names =
    match since with
      | None -> names
      | Some a ->
          let first = shard a ^ suffix in
          List.filter (fun n -> compare n first >= 0) names
  in
  let after entry_key =
    match since with
      | None -> true
      | Some a -> Journal.Entry_key.compare entry_key a > 0
  in
  (* One past [limit], which is how [more] is answered without a second pass. *)
  let want = limit + 1 in
  let rec walk acc taken = function
    | [] -> Lwt.return (List.rev acc)
    | _ when taken >= want -> Lwt.return (List.rev acc)
    | name :: rest ->
        let* entries = read_shard ~cache_root ~domain_name name in
        let acc, taken =
          List.fold_left
            (fun (acc, taken) entry ->
              if taken >= want || not (after (fst entry)) then (acc, taken)
              else (entry :: acc, taken + 1))
            (acc, taken) entries
        in
        walk acc taken rest
  in
  let+ found = walk [] 0 names in
  {
    entries = List.filteri (fun i _ -> i < limit) found;
    more = List.length found > limit;
  }

(* Enough of one end of a shard to hold a whole line, so neither of these reads
   a month of entries to answer with one. *)
let edge_bytes = 8192

let read_edge ~cache_root ~domain_name ~last name =
  let path = Filename.concat (dir ~cache_root ~domain_name) name in
  let* fd = Lwt_unix.openfile path [Unix.O_RDONLY] 0 in
  Lwt.finalize
    (fun () ->
      let* st = Lwt_unix.LargeFile.fstat fd in
      let size = Int64.to_int st.Unix.LargeFile.st_size in
      let len = min size edge_bytes in
      let off = if last then size - len else 0 in
      let* _ = Lwt_unix.LargeFile.lseek fd (Int64.of_int off) Unix.SEEK_SET in
      let buf = Bytes.create len in
      let rec fill got =
        if got >= len then Lwt.return got
        else
          let* n = Lwt_unix.read fd buf got (len - got) in
          if n = 0 then Lwt.return got else fill (got + n)
      in
      let+ got = fill 0 in
      let text = Bytes.sub_string buf 0 got in
      (* The edge read cuts a line in half: at the tail that is the first line,
         at the head the last. [decode] drops it either way. *)
      List.filter_map decode (String.split_on_char '\n' text))
    (fun () -> Lwt_unix.close fd)

let edge ~cache_root ~domain_name ~last () =
  let* names = shards ~cache_root ~domain_name in
  match if last then List.rev names else names with
    | [] -> Lwt.return_none
    | name :: _ -> (
        let+ entries = read_edge ~cache_root ~domain_name ~last name in
        match List.sort Journal.Entry_key.compare (List.map fst entries) with
          | [] -> None
          | sorted ->
              Some
                (List.nth sorted (if last then List.length sorted - 1 else 0)))

let head ~cache_root ~domain_name = edge ~cache_root ~domain_name ~last:true ()

let oldest ~cache_root ~domain_name =
  edge ~cache_root ~domain_name ~last:false ()

type shard_stat = { name : string; size : int; mtime : float }

let prune ~cache_root ~domain_name ~keep_days ~keep_bytes =
  let d = dir ~cache_root ~domain_name in
  let* names = shards ~cache_root ~domain_name in
  let cutoff = Unix.gettimeofday () -. (float_of_int keep_days *. 86400.) in
  let* sized =
    Lwt_list.map_s
      (fun name ->
        let+ st = Io_lwt.Fs.stat_opt_large (Filename.concat d name) in
        match st with
          | None -> { name; size = 0; mtime = 0. }
          | Some st ->
              {
                name;
                size = Int64.to_int st.Unix.LargeFile.st_size;
                mtime = st.Unix.LargeFile.st_mtime;
              })
      names
  in
  (* Newest shard first, so what is dropped is always the far end of the
     window and never a hole in the middle of it. *)
  let _, drop =
    List.fold_left
      (fun (held, drop) s ->
        if s.mtime < cutoff || held + s.size > keep_bytes then
          (held, s.name :: drop)
        else (held + s.size, drop))
      (0, []) (List.rev sized)
  in
  let dropped = List.filter (fun s -> List.mem s.name drop) sized in
  let+ () =
    Lwt_list.iter_s
      (fun name -> Io_lwt.Fs.unlink_quiet (Filename.concat d name))
      drop
  in
  (List.length dropped, List.fold_left (fun total s -> total + s.size) 0 dropped)
