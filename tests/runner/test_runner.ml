type step =
  | Write of { path : string; content : string }
  | Mkdir of string
  | Rmdir of string
  | Rename of { src : string; dst : string }
  | Delete of string
  | Evict of string
  | Restore of string
  | Drain

type scenario = { name : string; steps : step list }

(* ── Helpers ──────────────────────────────────────────────────────────────── *)

let rec rm_rf path =
  match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter
          (fun name -> rm_rf (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let write_file path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let render_step = function
  | Write { path; content } -> Printf.sprintf "write %s %S" path content
  | Mkdir p -> "mkdir " ^ p
  | Rmdir p -> "rmdir " ^ p
  | Rename { src; dst } -> Printf.sprintf "rename %s -> %s" src dst
  | Delete p -> "delete " ^ p
  | Evict p -> "evict " ^ p
  | Restore p -> "restore " ^ p
  | Drain -> "drain"

let render_op = function
  | `Put (k, size) -> Printf.sprintf "put %s %Ld" k size
  | `Delete k -> "delete " ^ k
  | `Mkdir k -> "mkdir " ^ k
  | `Rmdir k -> "rmdir " ^ k
  | `Rename { Journal.src; dst; size; is_dir } ->
      Printf.sprintf "rename %s -> %s%s%s" src dst
        (if is_dir then " dir" else "")
        (match size with Some s -> Printf.sprintf " %Ld" s | None -> "")

let starts_with prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* ── Runner ───────────────────────────────────────────────────────────────── *)

let run_scenario { name; steps } =
  Printf.printf "=== %s\n" name;
  List.iter (fun s -> Printf.printf "  %s\n" (render_step s)) steps;
  let root = Filename.temp_dir "tsync-test" "" in
  let backend_root = Filename.concat root "backend" in
  let module C = struct
    let versioning = false
    let domain_name = "test"
    let domain_prefix = "tsync/test/"
    let chunk_prefix = "tsync/.chunks/"
    let trash_prefix = "tsync/.trash/test/"
    let journal_prefix = "tsync/.journal/test/"
    let version_key = "tsync/.version/test"
    let backends = [Local_backend.make ~root:backend_root]
    let cache_root = Filename.concat root "cache"
    let data_dir = Filename.concat root "data"
    let socket_path = Filename.concat root "tsync.sock"
    let notify_path = Filename.concat root "notify.sock"
  end in
  let module Sq = Sync_queue.Make (C) in
  let module F = File.Make (C) (Sq) in
  let module H = Ipc_handler.Make (C) (F) in
  let key p = C.domain_prefix ^ p in
  let strip_root p =
    if String.length p > 0 && p.[0] = '/' then
      String.sub p 1 (String.length p - 1)
    else p
  in
  let hooks =
    H.
      {
        path_to_key = (fun p -> key (strip_root p));
        request_evict = F.evict;
        restore = F.ensure_cached;
        full_resync = (fun () -> ());
        status_fields = (fun () -> []);
        on_stop = (fun () -> ());
      }
  in
  Sq.start
    ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
    ~on_version:(fun ~entry_key:_ -> ())
    ~on_upload_done:(fun ~key:_ -> ());
  let server =
    Thread.create (fun () -> Ipc.serve ~path:C.socket_path (H.handler hooks)) ()
  in
  while not (Sys.file_exists C.socket_path) do
    Thread.yield ()
  done;
  let request fields =
    let line = Yojson.Safe.to_string (`Assoc fields) in
    match Yojson.Safe.from_string (Ipc.send ~socket_path:C.socket_path line) with
      | `Assoc obj -> obj
      | _ -> failwith "malformed IPC response"
  in
  let response_ok obj = List.assoc_opt "ok" obj = Some (`Bool true) in
  let response_error obj =
    match List.assoc_opt "error" obj with Some (`String s) -> s | _ -> "?"
  in
  let action ?src ?staging act path =
    request
      ([("action", `String act); ("path", `String path)]
      @ (match src with Some s -> [("src", `String s)] | None -> [])
      @ match staging with Some s -> [("staging", `String s)] | None -> [])
  in
  let must obj =
    if not (response_ok obj) then failwith ("IPC error: " ^ response_error obj)
  in
  let staging_seq = ref 0 in
  let do_step = function
    | Write { path; content } ->
        incr staging_seq;
        let staging =
          Filename.concat root (Printf.sprintf "staging-%d" !staging_seq)
        in
        write_file staging content;
        must (action ~staging "write" (key path))
    | Mkdir p -> must (action "mkdir" (key p ^ "/"))
    | Rmdir p -> must (action "rmdir" (key p ^ "/"))
    | Rename { src; dst } -> must (action ~src:(key src) "rename" (key dst))
    | Delete p -> must (action "delete" (key p))
    | Evict p -> must (action "evict" ("/" ^ p))
    | Restore p -> must (action "restore" ("/" ^ p))
    | Drain ->
        while not (Sq.idle ()) do
          Thread.yield ()
        done;
        (* Move past the current ms so the next journal entry key is distinct. *)
        Unix.sleepf 0.002
  in

  (* ── Snapshot ─────────────────────────────────────────────────────────── *)
  let get_str obj k =
    match List.assoc_opt k obj with Some (`String s) -> Some s | _ -> None
  in
  let dump_tree () =
    let files = ref [] in
    let rec walk prefix =
      let obj = action "list_dir" prefix in
      must obj;
      let dirs =
        match List.assoc_opt "dirs" obj with
          | Some (`List l) ->
              List.filter_map (function `String s -> Some s | _ -> None) l
          | _ -> []
      in
      let entries =
        match List.assoc_opt "files" obj with
          | Some (`List l) ->
              List.filter_map
                (function
                  | `Assoc f -> (
                      match get_str f "key" with
                        | Some k -> Some (F.rel_key k)
                        | None -> None)
                  | _ -> None)
                l
          | _ -> []
      in
      List.iter
        (fun rel ->
          let st = action "stat" (key rel) in
          let uploaded = List.assoc_opt "isUploaded" st = Some (`Bool true) in
          let etag = Option.value ~default:"" (get_str st "etag") in
          let size =
            match List.assoc_opt "size" st with Some (`Int n) -> n | _ -> -1
          in
          Printf.printf "  f %s size=%d cached=%b uploaded=%b etag=%s\n" rel size
            (F.is_cached (key rel))
            uploaded etag;
          files := rel :: !files)
        (List.sort compare entries);
      List.iter
        (fun d ->
          Printf.printf "  d %s/\n" (F.rel_key (prefix ^ d));
          walk (prefix ^ d ^ "/"))
        (List.sort compare dirs)
    in
    walk C.domain_prefix;
    List.rev !files
  in
  let dump_contents files =
    List.iter
      (fun rel ->
        let obj = action "ensure_cached" (key rel) in
        must obj;
        match get_str obj "localPath" with
          | Some lp -> Printf.printf "  %s = %S\n" rel (read_file lp)
          | None -> failwith "no localPath")
      files
  in
  let dump_backend () =
    let (module B : Backend.S) = Local_backend.make ~root:backend_root in
    let entries = B.list_all ~prefix:"" () in
    let journal_names =
      List.filter_map
        (fun (e : Backend.file_entry) ->
          if starts_with C.journal_prefix e.key then
            Some (Filename.basename e.key)
          else None)
        entries
      |> List.sort compare
    in
    let entry_alias name =
      let rec index i = function
        | [] -> name
        | n :: _ when n = name -> Printf.sprintf "<entry-%d>" (i + 1)
        | _ :: rest -> index (i + 1) rest
      in
      index 0 journal_names
    in
    List.iter
      (fun (e : Backend.file_entry) ->
        if starts_with C.chunk_prefix e.key then
          Printf.printf "  chunk %s size=%d\n"
            (String.sub e.key
               (String.length C.chunk_prefix)
               (String.length e.key - String.length C.chunk_prefix))
            e.size
        else if starts_with C.journal_prefix e.key then begin
          let ops = Journal.decode (B.get ~key:e.key ()) in
          Printf.printf "  journal %s = %s\n"
            (entry_alias (Filename.basename e.key))
            (String.concat "; " (List.map render_op ops))
        end
        else if e.key = C.version_key then
          Printf.printf "  version = %s\n"
            (entry_alias (String.trim (B.get ~key:e.key ())))
        else if starts_with C.domain_prefix e.key then begin
          let rel = F.rel_key e.key in
          if String.length e.key > 0 && e.key.[String.length e.key - 1] = '/'
          then Printf.printf "  dir %s\n" rel
          else (
            match Manifest.of_string (B.get ~key:e.key ()) with
              | `Clean m ->
                  Printf.printf "  file %s = manifest size=%Ld chunks=%d\n" rel
                    m.Manifest.size
                    (List.length m.Manifest.chunks)
              | `Dirty -> Printf.printf "  file %s = dirty\n" rel
              | exception _ ->
                  Printf.printf "  file %s = raw size=%d\n" rel e.size)
        end
        else Printf.printf "  other %s size=%d\n" e.key e.size)
      entries
  in
  (try
     List.iter do_step steps;
     Sq.drain ();
     print_endline "--- tree";
     let files = dump_tree () in
     print_endline "--- content";
     dump_contents files;
     print_endline "--- backend";
     dump_backend ()
   with exn -> Printf.printf "  ERROR %s\n" (Printexc.to_string exn));
  ignore (request [("action", `String "stop")]);
  Thread.join server;
  Sq.drain ();
  rm_rf root;
  print_newline ()

let run scenarios = List.iter run_scenario scenarios
