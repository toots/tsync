open Lwt.Syntax

let suffix = ".log"

(* How far back an entry is remembered, and so how far behind the present a
   store entry can appear and still be told from one already handled. *)
let keep_days = 30

let dir ~cache_root ~domain_name =
  Cache_layout.applied_dir ~cache_root domain_name

(* Sharded by when an entry was applied, not by the month in its key. The log
   is read as a sequence, and a peer's entry can be applied after entries whose
   keys are newer: a slow upload, or a record published after a crash under the
   key it was minted with. Filing it by its key would put it behind entries a
   reader had already been given. *)
let shard_of ~now =
  let tm = Unix.gmtime now in
  Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)

let shard_path ~cache_root ~domain_name ~now =
  Filename.concat (dir ~cache_root ~domain_name) (shard_of ~now ^ suffix)

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

(* [now] is the application time, and is a parameter only so a test can cross a
   shard boundary without waiting for the calendar. *)
let note ?(now = Unix.gettimeofday ()) ~cache_root ~domain_name entry_key ops =
  let* () = Io_lwt.Fs.mkdir_p (dir ~cache_root ~domain_name) in
  let path = shard_path ~cache_root ~domain_name ~now in
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

let rec following anchor = function
  | [] -> None
  | (k, _) :: rest ->
      if Journal.Entry_key.compare k anchor = 0 then Some rest
      else following anchor rest

(* What was appended after the anchor, in the order it was appended, whatever
   the keys say: the anchor is a position in this log, not a point in time. A
   reader comparing keys would never hear of an entry applied late with an older
   key. [None] when the anchor is no longer kept, so the reader starts over. *)
let since ~cache_root ~domain_name ?since ~limit () =
  let* names = shards ~cache_root ~domain_name in
  let read = read_shard ~cache_root ~domain_name in
  let* found =
    match since with
      | None ->
          let+ all = Lwt_list.map_s read names in
          Some (List.concat all)
      | Some anchor ->
          (* Newest shard first, so only the shards after the anchor are read. *)
          let rec back newer = function
            | [] -> Lwt.return_none
            | name :: older -> (
                let* entries = read name in
                match following anchor entries with
                  | Some tail -> Lwt.return_some (tail @ newer)
                  | None -> back (entries @ newer) older)
          in
          back [] (List.rev names)
  in
  Lwt.return
    (Option.map
       (fun found ->
         {
           entries = List.filteri (fun i _ -> i < limit) found;
           more = List.length found > limit;
         })
       found)

(* Every key kept, for a reader deciding which of a store's entries it has
   already handled. *)
let keys ~cache_root ~domain_name =
  let* names = shards ~cache_root ~domain_name in
  let+ pages = Lwt_list.map_s (read_shard ~cache_root ~domain_name) names in
  List.map fst (List.concat pages)

(* Enough of the end of a shard to hold a whole line, so the head is not a
   month of entries read to answer with one. *)
let edge_bytes = 8192

let read_tail ~cache_root ~domain_name name =
  let path = Filename.concat (dir ~cache_root ~domain_name) name in
  let* fd = Lwt_unix.openfile path [Unix.O_RDONLY] 0 in
  Lwt.finalize
    (fun () ->
      let* st = Lwt_unix.LargeFile.fstat fd in
      let size = Int64.to_int st.Unix.LargeFile.st_size in
      let len = min size edge_bytes in
      let* _ =
        Lwt_unix.LargeFile.lseek fd (Int64.of_int (size - len)) Unix.SEEK_SET
      in
      let buf = Bytes.create len in
      let rec fill got =
        if got >= len then Lwt.return got
        else
          let* n = Lwt_unix.read fd buf got (len - got) in
          if n = 0 then Lwt.return got else fill (got + n)
      in
      let+ got = fill 0 in
      let text = Bytes.sub_string buf 0 got in
      (* The read cuts the first line in half, and [decode] drops it. *)
      List.filter_map decode (String.split_on_char '\n' text))
    (fun () -> Lwt_unix.close fd)

(* The last entry appended, which is where a reader that has everything stands. *)
let head ~cache_root ~domain_name =
  let* names = shards ~cache_root ~domain_name in
  match List.rev names with
    | [] -> Lwt.return_none
    | name :: _ -> (
        let+ entries = read_tail ~cache_root ~domain_name name in
        match List.rev entries with [] -> None | (k, _) :: _ -> Some k)

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
