open Lwt.Syntax

type step =
  | Write of { path : string; content : string }
  | Mkdir of string
  | Rmdir of string
  | Rename of { src : string; dst : string }
  | Delete of string
  | Evict of string
  | Restore of string
  | RevertVersion of { path : string; version : string option }
  | Open of string
  | Close of string
  | Mark  (** record the current time, as an [Expire "mark"] cutoff *)
  | Expire of string
      (** cutoff selector: "all" (now), "none" (epoch), or "mark" *)
  | Drain
  | Sync

type scenario = { name : string; steps : step list }
type two_client_step = A of step | B of step
type two_client_scenario = { name : string; steps : two_client_step list }

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

let render_op = function
  | `Put (k, size) -> Printf.sprintf "put %s %Ld" k size
  | `Delete k -> "delete " ^ k
  | `Mkdir k -> "mkdir " ^ k
  | `Rmdir k -> "rmdir " ^ k
  | `Rename { Journal.src; dst; size; is_dir } ->
      Printf.sprintf "rename %s -> %s%s%s" src dst
        (if is_dir then " dir" else "")
        (match size with Some s -> Printf.sprintf " %Ld" s | None -> "")

let render_step = function
  | Write { path; content } -> Printf.sprintf "write %s %S" path content
  | Mkdir p -> "mkdir " ^ p
  | Rmdir p -> "rmdir " ^ p
  | Rename { src; dst } -> Printf.sprintf "rename %s -> %s" src dst
  | Delete p -> "delete " ^ p
  | Evict p -> "evict " ^ p
  | Restore p -> "restore " ^ p
  | RevertVersion { path; version } ->
      Printf.sprintf "revert %s%s" path
        (match version with Some v -> " @" ^ v | None -> " @latest")
  | Open p -> "open " ^ p
  | Close p -> "close " ^ p
  | Mark -> "mark"
  | Expire s -> "expire " ^ s
  | Drain -> "drain"
  | Sync -> "sync"

let starts_with prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* ── Client setup ─────────────────────────────────────────────────────────── *)

type client = {
  do_step : step -> unit Lwt.t;
  drain : unit -> unit Lwt.t;
  stop : unit -> unit Lwt.t;
  dump_tree : unit -> string list Lwt.t;
  dump_contents : string list -> unit Lwt.t;
  dump_pending : unit -> unit Lwt.t;
}

(* Tests drive the real IPC handler directly (no socket): every daemon service
   and the handler all run on the one Lwt event loop [run_scenario] spins up. *)
let setup_client (module C : Conf.S) root staging_prefix =
  let module Sq = Sync_queue.Make (C) in
  let module F = File.Make (C) (Sq) in
  let module H = Ipc_handler.Make (C) (F) in
  let module Sp = Sync_poller.Make (C) (F) in
  let module J = Journal.Make (C) in
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
        changed = (fun _ -> ());
        full_resync = (fun () -> Lwt.return_unit);
        status_fields = (fun () -> []);
        on_stop = (fun () -> ());
      }
  in
  Sq.start
    ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
    ~on_cursor:(fun ~entry_key:_ -> ())
    ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);
  let staging_seq = ref 0 in
  let mark_time = ref 0. in
  let request fields =
    let line = Yojson.Safe.to_string (`Assoc fields) in
    let* resp, _ctl = H.handler hooks line in
    match Yojson.Safe.from_string resp with
      | `Assoc obj -> Lwt.return obj
      | _ -> failwith "malformed IPC response"
  in
  let response_ok obj = List.assoc_opt "ok" obj = Some (`Bool true) in
  let response_error obj =
    match List.assoc_opt "error" obj with Some (`String s) -> s | _ -> "?"
  in
  let action ?src ?staging ?arg act path =
    request
      ([("action", `String act); ("path", `String path)]
      @ (match src with Some s -> [("src", `String s)] | None -> [])
      @ (match arg with Some s -> [("arg", `String s)] | None -> [])
      @ match staging with Some s -> [("staging", `String s)] | None -> [])
  in
  let must obj =
    if not (response_ok obj) then failwith ("IPC error: " ^ response_error obj)
  in
  let must_action ?src ?staging ?arg act path =
    let+ obj = action ?src ?staging ?arg act path in
    must obj
  in
  let do_step = function
    | Write { path; content } ->
        incr staging_seq;
        let staging =
          Filename.concat root
            (Printf.sprintf "staging-%s%d" staging_prefix !staging_seq)
        in
        write_file staging content;
        must_action ~staging "write" (key path)
    | Mkdir p -> must_action "mkdir" (key p ^ "/")
    | Rmdir p -> must_action "rmdir" (key p ^ "/")
    | Rename { src; dst } -> must_action ~src:(key src) "rename" (key dst)
    | Delete p -> must_action "delete" (key p)
    | Evict p -> must_action "evict" ("/" ^ p)
    | Restore p -> must_action "restore" ("/" ^ p)
    | RevertVersion { path; version } ->
        must_action ?arg:version "revert" ("/" ^ path)
    | Open p ->
        F.mark_open (key p);
        Lwt.return_unit
    | Close p ->
        ignore (F.mark_closed (key p));
        Lwt.return_unit
    | Mark ->
        mark_time := Unix.gettimeofday ();
        Lwt.return_unit
    | Expire selector ->
        let module E = Expire.Make (C) in
        let cutoff =
          match selector with
            | "all" -> Unix.gettimeofday ()
            | "none" -> 0.
            | "mark" -> !mark_time
            | _ -> failwith ("unknown expire selector: " ^ selector)
        in
        let+ s = E.expire ~cutoff () in
        Printf.printf
          "  expire %s -> %d version(s), %d chunk(s) removed, %d kept\n"
          selector s.Expire.versions_deleted s.chunks_deleted s.chunks_kept
    | Drain ->
        let rec wait () =
          if Sq.idle () then Lwt.return_unit
          else
            let* () = Lwt.pause () in
            wait ()
        in
        let* () = wait () in
        (* Move past the current ms so the next journal entry key is distinct. *)
        Lwt_unix.sleep 0.002
    | Sync -> Sp.sync_once ()
  in
  let drain () = Sq.drain () in
  let stop () = Lwt.return_unit in
  let get_str obj k =
    match List.assoc_opt k obj with Some (`String s) -> Some s | _ -> None
  in
  let dump_tree () =
    let files = ref [] in
    let rec walk prefix =
      let* obj = action "list_dir" prefix in
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
      let* () =
        Lwt_list.iter_s
          (fun rel ->
            let* st = action "stat" (key rel) in
            let uploaded = List.assoc_opt "isUploaded" st = Some (`Bool true) in
            let etag = Option.value ~default:"" (get_str st "etag") in
            let size =
              match List.assoc_opt "size" st with Some (`Int n) -> n | _ -> -1
            in
            let+ cached = F.is_cached (key rel) in
            Printf.printf "  f %s size=%d cached=%b uploaded=%b etag=%s\n" rel
              size cached uploaded etag;
            files := rel :: !files)
          (List.sort compare entries)
      in
      Lwt_list.iter_s
        (fun d ->
          Printf.printf "  d %s/\n" (F.rel_key (prefix ^ d));
          walk (prefix ^ d ^ "/"))
        (List.sort compare dirs)
    in
    let+ () = walk C.domain_prefix in
    List.rev !files
  in
  let dump_contents files =
    Lwt_list.iter_s
      (fun rel ->
        let* obj = action "ensure_cached" (key rel) in
        must obj;
        match get_str obj "localPath" with
          | Some lp ->
              Printf.printf "  %s = %S\n" rel (read_file lp);
              Lwt.return_unit
          | None -> failwith "no localPath")
      files
  in
  let dump_pending () =
    let+ pending = J.local_pending_entries ~uuid:(J.client_uuid ()) in
    List.iter
      (fun (_, ops) ->
        Printf.printf "  pending [%s]\n"
          (String.concat "; " (List.map render_op ops)))
      pending
  in
  { do_step; drain; stop; dump_tree; dump_contents; dump_pending }

(* ── Backend snapshot (shared between single- and two-client runners) ─────── *)

let dump_backend_at ~backend_root ~domain_prefix ~chunk_prefix ~journal_prefix
    ~versions_prefix ~cursor_key =
  let (module B : Backend.S) = Local_backend.make ~root:backend_root in
  let rel_key k =
    let pfx = String.length domain_prefix in
    if String.length k > pfx then String.sub k pfx (String.length k - pfx)
    else k
  in
  let* entries = B.list_all ~prefix:"" () in
  (* Alias non-deterministic nanosecond version timestamps as stable per-file
     indices (<rel>#1, <rel>#2, …) ordered oldest-first. *)
  let version_alias = Hashtbl.create 16 in
  let version_entries =
    List.filter_map
      (fun (e : Backend.file_entry) ->
        match Versioning.parse ~versions_prefix e.key with
          | Some (rel, ts) -> Some (rel, Int64.of_string ts, e.key)
          | None -> None)
      entries
  in
  List.iter
    (fun rel ->
      List.filter (fun (r, _, _) -> r = rel) version_entries
      |> List.sort (fun (_, a, _) (_, b, _) -> Int64.compare a b)
      |> List.iteri (fun i (_, _, k) -> Hashtbl.replace version_alias k (i + 1)))
    (List.sort_uniq compare (List.map (fun (r, _, _) -> r) version_entries));
  let journal_names =
    List.filter_map
      (fun (e : Backend.file_entry) ->
        if starts_with journal_prefix e.key then Some (Filename.basename e.key)
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
  let is_marker k = String.length k > 0 && k.[String.length k - 1] = '/' in
  Lwt_list.iter_s
    (fun (e : Backend.file_entry) ->
      (* Internal prefixes have no meaningful directories; ignore the empty-dir
         markers the local backend surfaces where S3 would list nothing. *)
      if
        is_marker e.key
        && (starts_with chunk_prefix e.key || starts_with versions_prefix e.key)
      then Lwt.return_unit
      else if starts_with chunk_prefix e.key then (
        Printf.printf "  chunk %s size=%d\n"
          (String.sub e.key
             (String.length chunk_prefix)
             (String.length e.key - String.length chunk_prefix))
          e.size;
        Lwt.return_unit)
      else if starts_with journal_prefix e.key then
        let+ data = B.get ~key:e.key () in
        let ops = Journal.decode data in
        Printf.printf "  journal %s = %s\n"
          (entry_alias (Filename.basename e.key))
          (String.concat "; " (List.map render_op ops))
      else if e.key = cursor_key then
        let+ data = B.get ~key:e.key () in
        Printf.printf "  cursor = %s\n" (entry_alias (String.trim data))
      else if starts_with versions_prefix e.key then (
        match Versioning.parse ~versions_prefix e.key with
          | Some (rel, _) ->
              let n =
                Option.value ~default:0 (Hashtbl.find_opt version_alias e.key)
              in
              let+ data = B.get ~key:e.key () in
              let desc =
                match Manifest.of_string data with
                  | `Clean m ->
                      Printf.sprintf "manifest size=%Ld chunks=%d"
                        m.Manifest.size
                        (List.length m.Manifest.chunks)
                  | `Dirty -> "dirty"
                  | exception _ -> "raw"
              in
              Printf.printf "  version %s#%d = %s\n" rel n desc
          | None ->
              Printf.printf "  other %s size=%d\n" e.key e.size;
              Lwt.return_unit)
      else if starts_with domain_prefix e.key then (
        let rel = rel_key e.key in
        if String.length e.key > 0 && e.key.[String.length e.key - 1] = '/' then (
          Printf.printf "  dir %s\n" rel;
          Lwt.return_unit)
        else
          let+ data = B.get ~key:e.key () in
          match Manifest.of_string data with
            | `Clean m ->
                Printf.printf "  file %s = manifest size=%Ld chunks=%d\n" rel
                  m.Manifest.size
                  (List.length m.Manifest.chunks)
            | `Dirty -> Printf.printf "  file %s = dirty\n" rel
            | exception _ ->
                Printf.printf "  file %s = raw size=%d\n" rel e.size)
      else (
        Printf.printf "  other %s size=%d\n" e.key e.size;
        Lwt.return_unit))
    entries

(* ── Scenario runners ─────────────────────────────────────────────────────── *)

let run_scenario ?(versioning = false) ({ name; steps } : scenario) =
  Printf.printf "=== %s\n" name;
  List.iter (fun s -> Printf.printf "  %s\n" (render_step s)) steps;
  let root = Filename.temp_dir "tsync-test" "" in
  let backend_root = Filename.concat root "backend" in
  let module C = struct
    let versioning = versioning
    let client_name = "Test Client"
    let domain_name = "test"
    let domain_prefix = "tsync/test/"
    let chunk_prefix = "tsync/.chunks/"
    let versions_prefix = "tsync/.versions/test/"
    let journal_prefix = "tsync/.journal/test/"
    let cursor_key = "tsync/.cursor/test"
    let backends = [Local_backend.make ~root:backend_root]
    let cache_root = Filename.concat root "cache"
    let data_dir = Filename.concat root "data"
    let socket_path = Filename.concat root "tsync.sock"
    let notify_path = Filename.concat root "notify.sock"
  end in
  Lwt_main.run
    (let client = setup_client (module C) root "" in
     let* () =
       Lwt.catch
         (fun () ->
           let* () = Lwt_list.iter_s client.do_step steps in
           let* () = client.drain () in
           print_endline "--- tree";
           let* files = client.dump_tree () in
           print_endline "--- content";
           let* () = client.dump_contents files in
           print_endline "--- backend";
           dump_backend_at ~backend_root ~domain_prefix:C.domain_prefix
             ~chunk_prefix:C.chunk_prefix ~journal_prefix:C.journal_prefix
             ~versions_prefix:C.versions_prefix ~cursor_key:C.cursor_key)
         (fun exn ->
           Printf.printf "  ERROR %s\n" (Printexc.to_string exn);
           Lwt.return_unit)
     in
     client.stop ());
  rm_rf root;
  print_newline ()

let run_two_client_scenario ?(versioning = false)
    ({ name; steps } : two_client_scenario) =
  Printf.printf "=== %s\n" name;
  List.iter
    (fun s ->
      Printf.printf "  %s: %s\n"
        (match s with A _ -> "A" | B _ -> "B")
        (render_step (match s with A s | B s -> s)))
    steps;
  let root = Filename.temp_dir "tsync-test-2" "" in
  let backend_root = Filename.concat root "backend" in
  let shared_backends = [Local_backend.make ~root:backend_root] in
  let module Ca = struct
    let versioning = versioning
    let client_name = "Client A"
    let domain_name = "test"
    let domain_prefix = "tsync/test/"
    let chunk_prefix = "tsync/.chunks/"
    let versions_prefix = "tsync/.versions/test/"
    let journal_prefix = "tsync/.journal/test/"
    let cursor_key = "tsync/.cursor/test"
    let backends = shared_backends
    let cache_root = Filename.concat root "cache-a"
    let data_dir = Filename.concat root "data-a"
    let socket_path = Filename.concat root "tsync-a.sock"
    let notify_path = Filename.concat root "notify-a.sock"
  end in
  let module Cb = struct
    let versioning = versioning
    let client_name = "Client B"
    let domain_name = "test"
    let domain_prefix = "tsync/test/"
    let chunk_prefix = "tsync/.chunks/"
    let versions_prefix = "tsync/.versions/test/"
    let journal_prefix = "tsync/.journal/test/"
    let cursor_key = "tsync/.cursor/test"
    let backends = shared_backends
    let cache_root = Filename.concat root "cache-b"
    let data_dir = Filename.concat root "data-b"
    let socket_path = Filename.concat root "tsync-b.sock"
    let notify_path = Filename.concat root "notify-b.sock"
  end in
  Lwt_main.run
    (let client_a = setup_client (module Ca) root "a" in
     let client_b = setup_client (module Cb) root "b" in
     let dispatch = function
       | A s -> client_a.do_step s
       | B s -> client_b.do_step s
     in
     let* () =
       Lwt.catch
         (fun () ->
           let* () = Lwt_list.iter_s dispatch steps in
           let* () = client_a.drain () in
           let* () = client_b.drain () in
           print_endline "--- tree A";
           let* files_a = client_a.dump_tree () in
           print_endline "--- content A";
           let* () = client_a.dump_contents files_a in
           print_endline "--- pending A";
           let* () = client_a.dump_pending () in
           print_endline "--- tree B";
           let* files_b = client_b.dump_tree () in
           print_endline "--- content B";
           let* () = client_b.dump_contents files_b in
           print_endline "--- pending B";
           let* () = client_b.dump_pending () in
           print_endline "--- backend";
           dump_backend_at ~backend_root ~domain_prefix:Cb.domain_prefix
             ~chunk_prefix:Cb.chunk_prefix ~journal_prefix:Cb.journal_prefix
             ~versions_prefix:Cb.versions_prefix ~cursor_key:Cb.cursor_key)
         (fun exn ->
           Printf.printf "  ERROR %s\n" (Printexc.to_string exn);
           Lwt.return_unit)
     in
     let* () = client_a.stop () in
     client_b.stop ());
  rm_rf root;
  print_newline ()

let run ?versioning scenarios = List.iter (run_scenario ?versioning) scenarios

let run_two_client_scenarios ?versioning scenarios =
  List.iter (run_two_client_scenario ?versioning) scenarios
