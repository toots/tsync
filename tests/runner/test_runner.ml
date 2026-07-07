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
  | DeleteRemoteChunk of { path : string; index : int }
  | CorruptRemoteChunk of { path : string; index : int }
  | DeleteRemoteManifest of string
  | DirtyWrite of { path : string; content : string }
  | ModifyCache of { path : string; content : string }
  | Recheck
  | OnSecondary of step
  | ResyncRemote
  | ImportDir of (string * string) list
  | ExportDir

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

let rec render_step = function
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
  | DeleteRemoteChunk { path; index } ->
      Printf.sprintf "delete-remote-chunk %s #%d" path index
  | CorruptRemoteChunk { path; index } ->
      Printf.sprintf "corrupt-remote-chunk %s #%d" path index
  | DeleteRemoteManifest p -> "delete-remote-manifest " ^ p
  | DirtyWrite { path; content } ->
      Printf.sprintf "dirty-write %s %S" path content
  | ModifyCache { path; content } ->
      Printf.sprintf "modify-cache %s %S" path content
  | Recheck -> "recheck"
  | OnSecondary s -> "on-secondary " ^ render_step s
  | ResyncRemote -> "resync-remote"
  | ImportDir entries ->
      Printf.sprintf "import-dir %s"
        (String.concat " "
           (List.map (fun (p, c) -> Printf.sprintf "%s=%S" p c) entries))
  | ExportDir -> "export-dir"

let starts_with prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* ── IPC response snapshots ───────────────────────────────────────────────── *)

(* Render an IPC response verbatim, stabilising only the non-deterministic parts:
   wall-clock mtimes, journal-key cursors, and the filesystem-order [files]/[dirs]
   arrays. etags (content hashes) and keys are deterministic and shown as-is. *)
let ipc_entry_key = function
  | `Assoc kvs -> (
      match List.assoc_opt "key" kvs with Some (`String s) -> s | _ -> "")
  | _ -> ""

let rec normalize_ipc (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
    | `Assoc kvs -> `Assoc (List.map normalize_kv kvs)
    | `List l -> `List (List.map normalize_ipc l)
    | j -> j

and normalize_kv (k, v) =
  match (k, v) with
    | "mtime", `Float f -> (k, `String (if f > 0. then "<mtime>" else "<zero>"))
    | "cursor", `String s ->
        (k, `String (if s = "" then "<empty>" else "<cursor>"))
    | "files", `List l ->
        let l = List.map normalize_ipc l in
        ( k,
          `List
            (List.stable_sort
               (fun a b -> compare (ipc_entry_key a) (ipc_entry_key b))
               l) )
    | "dirs", `List l ->
        (k, `List (List.sort compare (List.map normalize_ipc l)))
    | k, v -> (k, normalize_ipc v)

let print_ipc label obj =
  Printf.printf "  %s -> %s\n" label
    (Yojson.Safe.to_string (normalize_ipc (`Assoc obj)))

(* ── Client setup ─────────────────────────────────────────────────────────── *)

type client = {
  do_step : step -> unit Lwt.t;
  drain : unit -> unit Lwt.t;
  stop : unit -> unit Lwt.t;
  dump_tree : unit -> string list Lwt.t;
  dump_contents : string list -> unit Lwt.t;
  dump_pending : unit -> unit Lwt.t;
  dump_listing : unit -> unit Lwt.t;
  dump_changes : label:string -> anchor:string -> unit Lwt.t;
  cursor : unit -> string Lwt.t;
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
        stats_fields = (fun () -> []);
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
  (* Backend damage for recheck scenarios: resolve a chunk key from the local
     sidecar, then delete or overwrite the remote object behind the daemon's
     back. *)
  let remote_chunk_key path index =
    let* m = F.read_manifest (key path) in
    match m with
      | Some (`Clean m) ->
          Lwt.return
            (C.chunk_prefix
            ^ Manifest.chunk_key (List.nth m.Manifest.chunks index))
      | _ -> failwith ("no clean sidecar for " ^ path)
  in
  let damage (module B : Backend.S) = function
    | DeleteRemoteChunk { path; index } ->
        let* ck = remote_chunk_key path index in
        B.delete ~key:ck ()
    | CorruptRemoteChunk { path; index } ->
        let* ck = remote_chunk_key path index in
        B.put ~key:ck ~data:"garbage" ()
    | DeleteRemoteManifest p -> B.delete ~key:(key p) ()
    | s -> failwith ("not a backend-damage step: " ^ render_step s)
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
    | (DeleteRemoteChunk _ | CorruptRemoteChunk _ | DeleteRemoteManifest _) as s
      ->
        damage (List.hd C.backends) s
    | OnSecondary s -> (
        match C.backends with
          | _ :: dst :: _ -> damage dst s
          | _ -> failwith "OnSecondary: no secondary backend configured")
    | ImportDir entries ->
        incr staging_seq;
        let src =
          Filename.concat root
            (Printf.sprintf "import-%s%d" staging_prefix !staging_seq)
        in
        List.iter
          (fun (rel, content) ->
            let path = Filename.concat src rel in
            let rec mkdir_p d =
              if not (Sys.file_exists d) then begin
                mkdir_p (Filename.dirname d);
                Unix.mkdir d 0o755
              end
            in
            mkdir_p (Filename.dirname path);
            write_file path content)
          entries;
        let module I = Import.Make (C) in
        let+ summary =
          I.run ~src
            ~on_file:(fun ~rel status ->
              match status with
                | Import.Imported size ->
                    Printf.printf "  imported %s (%Ld bytes)\n" rel size
                | Import.Skipped_exists ->
                    Printf.printf "  skip %s (exists)\n" rel)
            ()
        in
        Printf.printf "  import: %d imported, %d skipped\n"
          summary.Import.imported summary.Import.skipped
    | ExportDir ->
        incr staging_seq;
        let dst =
          Filename.concat root
            (Printf.sprintf "export-%s%d" staging_prefix !staging_seq)
        in
        let module E = Export.Make (C) in
        let* summary =
          E.run ~dst
            ~on_file:(fun ~rel status ->
              let desc =
                match status with
                  | Export.Exported Export.Local_cache -> "local cache"
                  | Export.Exported Export.Remote_chunks -> "remote"
                  | Export.Missing_data -> "MISSING"
              in
              Printf.printf "  export %s (%s)\n" rel desc)
            ()
        in
        Printf.printf "  export: %d exported, %d missing\n"
          summary.Export.exported summary.Export.missing;
        (* Dump the exported tree so snapshots pin the actual bytes written. *)
        let rec dump rel =
          let dir = if rel = "" then dst else Filename.concat dst rel in
          let* names = Fs_util.readdir_list dir in
          Lwt_list.iter_s
            (fun name ->
              let r = if rel = "" then name else rel ^ "/" ^ name in
              let* is_dir = Fs_util.is_directory (Filename.concat dst r) in
              if is_dir then dump r
              else (
                Printf.printf "  exported-file %s = %S\n" r
                  (read_file (Filename.concat dst r));
                Lwt.return_unit))
            (List.sort compare names)
        in
        dump ""
    | ResyncRemote ->
        let module M = Mirror.Make (C) in
        let+ dests = M.resync () in
        List.iter
          (fun (d : Mirror.dest_stats) ->
            List.iter (Printf.printf "  copied %s\n") d.Mirror.copied;
            (* Bytes are omitted: manifest objects embed mtimes, so their
               sizes are not deterministic. *)
            Printf.printf "  resync backend #%d: %d checked, %d copied\n"
              (d.Mirror.index + 1) d.Mirror.checked
              (List.length d.Mirror.copied))
          dests
    | DirtyWrite { path; content } ->
        (* A write that has not been uploaded yet, the way the FUSE layer
           leaves a file between write and close: local data plus a Dirty
           sidecar. *)
        write_file (F.local_path (key path)) content;
        F.mark_dirty (key path)
    | ModifyCache { path; content } ->
        (* Local data changed behind the daemon's back: the sidecar still
           describes the old content. *)
        write_file (F.local_path (key path)) content;
        Lwt.return_unit
    | Recheck ->
        let module Rc = Recheck.Make (C) in
        let* summary =
          Rc.run
            ~on_file:(fun ~rel status ->
              Printf.printf "  %s\n" (Recheck.describe rel status))
            ()
        in
        (match summary with
          | Some s ->
              Printf.printf
                "  recheck: %d checked, %d repaired, %d unrepairable, %d skipped\n"
                s.Recheck.checked s.Recheck.repaired s.Recheck.unrepairable
                s.Recheck.skipped
          | None -> Printf.printf "  recheck: no local cache\n");
        Lwt.return_unit
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
          (* [dirs] are full keys ending in "/". *)
          Printf.printf "  d %s\n" (F.rel_key d);
          walk d)
        (List.sort compare dirs)
    in
    let+ () = walk C.domain_prefix in
    List.rev !files
  in
  (* A failed fetch (e.g. an unrepairable evicted file) is part of the
     snapshot, not a reason to abort the remaining files' contents. *)
  let dump_contents files =
    Lwt_list.iter_s
      (fun rel ->
        let+ obj = action "ensure_cached" (key rel) in
        if not (response_ok obj) then
          Printf.printf "  %s = <unavailable: %s>\n" rel (response_error obj)
        else (
          match get_str obj "localPath" with
            | Some lp -> Printf.printf "  %s = %S\n" rel (read_file lp)
            | None -> failwith "no localPath"))
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
  (* Recursive list_dir (per directory) then the flat list_all working-set view —
     the actual IPC responses, normalized. *)
  let dump_listing () =
    let rec walk prefix =
      let* obj = action "list_dir" prefix in
      must obj;
      print_ipc (Printf.sprintf "list_dir %s" prefix) obj;
      let dirs =
        match List.assoc_opt "dirs" obj with
          | Some (`List l) ->
              List.filter_map (function `String s -> Some s | _ -> None) l
          | _ -> []
      in
      Lwt_list.iter_s walk (List.sort compare dirs)
    in
    let* () = walk C.domain_prefix in
    let* obj = action "list_all" C.domain_prefix in
    must obj;
    print_ipc (Printf.sprintf "list_all %s" C.domain_prefix) obj;
    Lwt.return_unit
  in
  let cursor () =
    let+ obj = action "cursor" "" in
    Option.value ~default:"" (get_str obj "cursor")
  in
  let dump_changes ~label ~anchor =
    let* obj = action ~arg:anchor "changes_since" "" in
    must obj;
    print_ipc (Printf.sprintf "changes_since %s" label) obj;
    Lwt.return_unit
  in
  {
    do_step;
    drain;
    stop;
    dump_tree;
    dump_contents;
    dump_pending;
    dump_listing;
    dump_changes;
    cursor;
  }

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
                Printf.printf
                  "  file %s = manifest size=%Ld chunks=%d h1=%s h2=%s\n" rel
                  m.Manifest.size
                  (List.length m.Manifest.chunks)
                  m.Manifest.h1 m.Manifest.h2;
                List.iter
                  (fun (c : Manifest.chunk_entry) ->
                    Printf.printf "    chunk#%d %s size=%d\n" c.index
                      (Manifest.chunk_key c) c.size)
                  m.Manifest.chunks
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
  let backend2_root = Filename.concat root "backend2" in
  (* The secondary backend exists in every scenario (writes fan out to all
     backends, as in the daemon); its state is only dumped for scenarios that
     actually exercise it. *)
  let uses_secondary =
    List.exists
      (function OnSecondary _ | ResyncRemote -> true | _ -> false)
      steps
  in
  let module C = struct
    let versioning = versioning
    let client_name = "Test Client"
    let domain_name = "test"
    let domain_prefix = "tsync/test/"
    let chunk_prefix = "tsync/.chunks/"
    let versions_prefix = "tsync/.versions/test/"
    let journal_prefix = "tsync/.journal/test/"
    let cursor_key = "tsync/.cursor/test"

    let backends =
      [
        Local_backend.make ~root:backend_root;
        Local_backend.make ~root:backend2_root;
      ]

    let cache_root = Filename.concat root "cache"
    let data_dir = Filename.concat root "data"
    let socket_path = Filename.concat root "tsync.sock"
    let notify_path = Filename.concat root "notify.sock"
    let max_uploads = 4
    let max_downloads = 8
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
           client.dump_contents files)
         (fun exn ->
           Printf.printf "  ERROR %s\n" (Printexc.to_string exn);
           Lwt.return_unit)
     in
     (* Outside the catch: the bucket snapshot must appear even when a step or
        content fetch fails (e.g. rechecking an unrepairable evicted file). *)
     print_endline "--- backend";
     let* () =
       dump_backend_at ~backend_root ~domain_prefix:C.domain_prefix
         ~chunk_prefix:C.chunk_prefix ~journal_prefix:C.journal_prefix
         ~versions_prefix:C.versions_prefix ~cursor_key:C.cursor_key
     in
     let* () =
       if uses_secondary then (
         print_endline "--- backend 2";
         dump_backend_at ~backend_root:backend2_root
           ~domain_prefix:C.domain_prefix ~chunk_prefix:C.chunk_prefix
           ~journal_prefix:C.journal_prefix ~versions_prefix:C.versions_prefix
           ~cursor_key:C.cursor_key)
       else Lwt.return_unit
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
    let max_uploads = 4
    let max_downloads = 8
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
    let max_uploads = 4
    let max_downloads = 8
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

(* ── IPC snapshot runners ─────────────────────────────────────────────────── *)

let make_conf ?(versioning = false) ~client_name ~backend_root ~cache_root
    ~data_dir ~socket_path ~notify_path () : (module Conf.S) =
  (module struct
    let versioning = versioning
    let client_name = client_name
    let domain_name = "test"
    let domain_prefix = "tsync/test/"
    let chunk_prefix = "tsync/.chunks/"
    let versions_prefix = "tsync/.versions/test/"
    let journal_prefix = "tsync/.journal/test/"
    let cursor_key = "tsync/.cursor/test"
    let backends = [Local_backend.make ~root:backend_root]
    let cache_root = cache_root
    let data_dir = data_dir
    let socket_path = socket_path
    let notify_path = notify_path
    let max_uploads = 4
    let max_downloads = 8
  end)

(* Single client: after draining uploads, snapshot the listing IPC responses
   (directory keys, logical size, content-hash etag, normalized mtime). *)
let run_ipc_scenario ?versioning ({ name; steps } : scenario) =
  Printf.printf "=== %s\n" name;
  List.iter (fun s -> Printf.printf "  %s\n" (render_step s)) steps;
  let root = Filename.temp_dir "tsync-ipc" "" in
  let module C =
    (val make_conf ?versioning ~client_name:"Test Client"
           ~backend_root:(Filename.concat root "backend")
           ~cache_root:(Filename.concat root "cache")
           ~data_dir:(Filename.concat root "data")
           ~socket_path:(Filename.concat root "s.sock")
           ~notify_path:(Filename.concat root "n.sock")
           ())
  in
  Lwt_main.run
    (let client = setup_client (module C) root "" in
     let* () =
       Lwt.catch
         (fun () ->
           let* () = Lwt_list.iter_s client.do_step steps in
           let* () = client.drain () in
           print_endline "--- listing";
           client.dump_listing ())
         (fun exn ->
           Printf.printf "  ERROR %s\n" (Printexc.to_string exn);
           Lwt.return_unit)
     in
     client.stop ());
  rm_rf root;
  print_newline ()

(* Two clients on one backend: A applies the steps, then B's change feed is
   probed from several anchors — a baseline (working delta), B's current cursor
   (up to date), and a pruned-past anchor (stale → full re-list). *)
let run_ipc_changes_scenario ?versioning ({ name; steps } : scenario) =
  Printf.printf "=== %s\n" name;
  List.iter (fun s -> Printf.printf "  A: %s\n" (render_step s)) steps;
  let root = Filename.temp_dir "tsync-ipc2" "" in
  let backend_root = Filename.concat root "backend" in
  let module Ca =
    (val make_conf ?versioning ~client_name:"Client A" ~backend_root
           ~cache_root:(Filename.concat root "cache-a")
           ~data_dir:(Filename.concat root "data-a")
           ~socket_path:(Filename.concat root "a.sock")
           ~notify_path:(Filename.concat root "na.sock")
           ())
  in
  let module Cb =
    (val make_conf ?versioning ~client_name:"Client B" ~backend_root
           ~cache_root:(Filename.concat root "cache-b")
           ~data_dir:(Filename.concat root "data-b")
           ~socket_path:(Filename.concat root "b.sock")
           ~notify_path:(Filename.concat root "nb.sock")
           ())
  in
  Lwt_main.run
    (let a = setup_client (module Ca) root "a" in
     let b = setup_client (module Cb) root "b" in
     let* () =
       Lwt.catch
         (fun () ->
           let* baseline = b.cursor () in
           let* () = Lwt_list.iter_s a.do_step steps in
           let* () = a.drain () in
           print_endline "--- B changes_since (A's ops are foreign to B)";
           let* () =
             b.dump_changes ~label:"from baseline (working)" ~anchor:baseline
           in
           let* current = b.cursor () in
           let* () =
             b.dump_changes ~label:"from current (up to date)" ~anchor:current
           in
           b.dump_changes ~label:"from pruned anchor (stale)"
             ~anchor:"0000000000001-deadbeef")
         (fun exn ->
           Printf.printf "  ERROR %s\n" (Printexc.to_string exn);
           Lwt.return_unit)
     in
     let* () = a.stop () in
     b.stop ());
  rm_rf root;
  print_newline ()

let run_ipc ?versioning scenarios =
  List.iter (run_ipc_scenario ?versioning) scenarios

let run_ipc_changes ?versioning scenarios =
  List.iter (run_ipc_changes_scenario ?versioning) scenarios
