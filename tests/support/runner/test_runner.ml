open Lwt.Syntax

(* Forced small via [TSYNC_CHUNK_SIZE] so a test exercises multi-chunk files
   without multi-megabyte fixtures. Each scenario's conf sets it explicitly and
   every manifest records its own, so nothing outside the tests reads this. *)
let env_int name ~default =
  match Sys.getenv_opt name with
    | Some s -> ( try int_of_string s with _ -> default)
    | None -> default

let chunk_size = env_int "TSYNC_CHUNK_SIZE" ~default:Conf.default_chunk_size

(* Equal to the stored chunk size unless a test sets [TSYNC_CACHE_CHUNK_SIZE], so
   grouping is opt-in. *)
let cache_chunk_size = env_int "TSYNC_CACHE_CHUNK_SIZE" ~default:chunk_size

type step =
  | Write of { path : string; content : string }
  | Symlink of { path : string; target : string }
  | Mkdir of string
  | Rmdir of string
  | Rename of { src : string; dst : string }
  | Delete of string
  | Evict of string
  | EnforceCache
      (** Run one best-effort cache-cap sweep (evict coldest clean files over
          the [max_cache] cap). *)
  | Restore of string
  | RevertVersion of { path : string; version : string option }
  | Close of string  (** Handle closed: queue the upload a staged file owes. *)
  | ReadRange of { path : string; offset : int; len : int }
      (** Read [len] bytes at [offset], fetching only the chunks they need, and
          print the bytes returned. *)
  | FetchRange of { path : string; offset : int; len : int }
      (** Serve one range into a file, the way the File Provider asks for a
          piece of a large file. *)
  | WriteAt of { path : string; offset : int; content : string }
      (** Write [content] at [offset] through the staged write path
          (read-modify-write of a partially covered chunk). *)
  | Truncate of { path : string; size : int }
  | ShowChunks of string
      (** Print what backs the file — published chunks or staged slots — and how
          many of its chunks are local. *)
  | ShowChunkCache
      (** Print the whole chunk store's size: [chunks=n bytes=b]. *)
  | ShowStaged
      (** Print the staged tree's contents: manifests and the bodies they are
          supposed to be the only reference to. *)
  | ShowNames of string
      (** Print the raw entry names FUSE readdir serves for a directory. *)
  | Stat of string
      (** Query a path through the IPC [stat] action. A query leaves nothing
          behind: an absent path answers "not found" and stays absent. *)
  | Mark  (** record the current time, as an [Expire "mark"] cutoff *)
  | Expire of string
      (** Cutoff selector: "all" (now), "none" (epoch), or "mark". *)
  | PurgeTrashed of string
  | Gc  (** Collect chunks nothing references. *)
  | GcVerify
  | GcMark  (** Collect as far as the end of marking; leave it open. *)
  | GcClose  (** Finish what [GcMark] left open. *)
  | GcAbort  (** Abandon an open collection, keeping everything. *)
  | Drain
  | Uploads of [ `Paused | `Running ]
  | Sync
  | DeleteRemoteChunk of { path : string; index : int }
  | CorruptRemoteChunk of { path : string; index : int }
  | ScrambleRemoteChunk of { path : string; index : int }
  | ScrambleBackendFile of { path : string; index : int }
  | ListCorrupted
  | RequestVerify
  | RescanCorrupted
  | Repair
  | DeleteRemoteManifest of string
  | StageWrite of { path : string; content : string }
      (** Replace the file's content locally without uploading: unsynced edits,
          the way a writer leaves a file between write and close. *)
  | DeleteCachedChunk of { path : string; index : int }
  | ForgetFolderId of string
  | RecoverStaged
      (** Finish or discard every unfinished record, and adopt staged data no
          record names, exactly as a restart does. *)
  | CrashBeforeCommit of string
      (** Upload the bytes, record them as executed, and stop before publishing
          the journal entry — the window a kill -9 mid-upload leaves. The change
          exists on the backend and no peer can see it. *)
  | StaleRecord
      (** Drop a record in the pre-state format naming a put whose data was
          never staged: what repeated replays left behind, 295 of them on one
          domain, before recovery kept one key per unit of work. *)
  | OrphanStagedBody
      (** Drop a staged body no manifest names into each body tree, the way a
          crash between staging and the manifest write does. *)
  | ReclaimStaged  (** Sweep unreferenced staged bodies, as a restart does. *)
  | ClearCache
      (** Wipe the local cache the way a full resync does: manifest mirror and
          chunk store, keeping only the staged tree. *)
  | OnSecondary of step
  | ResyncRemote
  | ResyncScoped of { path : string option }
  | LocalWrite of { path : string; content : string }
  | LocalMkdir of string
  | LocalSymlink of { path : string; target : string }
  | Import of { only : string list; exclude : string list; force_rehash : bool }
  | ExportDir

type scenario = { name : string; steps : step list }
type two_client_step = A of step | B of step
type two_client_scenario = { name : string; steps : two_client_step list }

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
  | `Mkdir (k, _) -> "mkdir " ^ k
  | `Rmdir (k, _) -> "rmdir " ^ k
  | `Rename { Journal.src; dst; size; is_dir; _ } ->
      Printf.sprintf "rename %s -> %s%s%s" src dst
        (if is_dir then " dir" else "")
        (match size with Some s -> Printf.sprintf " %Ld" s | None -> "")

let rec render_step = function
  | Write { path; content } -> Printf.sprintf "write %s %S" path content
  | Symlink { path; target } -> Printf.sprintf "symlink %s -> %s" path target
  | Mkdir p -> "mkdir " ^ p
  | Rmdir p -> "rmdir " ^ p
  | Rename { src; dst } -> Printf.sprintf "rename %s -> %s" src dst
  | Delete p -> "delete " ^ p
  | Evict p -> "evict " ^ p
  | EnforceCache -> "enforce-cache"
  | Restore p -> "restore " ^ p
  | RevertVersion { path; version } ->
      Printf.sprintf "revert %s%s" path
        (match version with Some v -> " @" ^ v | None -> " @latest")
  | Close p -> "close " ^ p
  | ReadRange { path; offset; len } ->
      Printf.sprintf "read %s [%d,%d)" path offset (offset + len)
  | FetchRange { path; offset; len } ->
      Printf.sprintf "fetch-range %s [%d,%d)" path offset (offset + len)
  | WriteAt { path; offset; content } ->
      Printf.sprintf "write-at %s @%d %S" path offset content
  | Truncate { path; size } -> Printf.sprintf "truncate %s %d" path size
  | ShowChunks p -> "chunks " ^ p
  | ShowChunkCache -> "chunk-cache"
  | ShowStaged -> "staged"
  | ShowNames p -> "names " ^ if p = "" then "/" else p
  | Stat p -> "stat " ^ p
  | Mark -> "mark"
  | Expire s -> "expire " ^ s
  | PurgeTrashed p -> "trash --purge " ^ p
  | Gc -> "gc"
  | GcVerify -> "gc --verify"
  | GcMark -> "gc (mark only)"
  | GcClose -> "gc (close)"
  | GcAbort -> "gc --abort"
  | Drain -> "drain"
  | Uploads `Paused -> "uploads paused"
  | Uploads `Running -> "uploads running"
  | Sync -> "sync"
  | DeleteRemoteChunk { path; index } ->
      Printf.sprintf "delete-remote-chunk %s #%d" path index
  | CorruptRemoteChunk { path; index } ->
      Printf.sprintf "corrupt-remote-chunk %s #%d" path index
  | ScrambleRemoteChunk { path; index } ->
      Printf.sprintf "scramble-remote-chunk %s #%d" path index
  | ScrambleBackendFile { path; index } ->
      Printf.sprintf "scramble-backend-file %s #%d" path index
  | ListCorrupted -> "list-corrupted"
  | RequestVerify -> "request-verify"
  | RescanCorrupted -> "rescan-corrupted"
  | Repair -> "repair"
  | DeleteRemoteManifest p -> "delete-remote-manifest " ^ p
  | StageWrite { path; content } ->
      Printf.sprintf "stage-write %s %S" path content
  | DeleteCachedChunk { path; index } ->
      Printf.sprintf "delete-cached-chunk %s #%d" path index
  | ForgetFolderId rel -> "forget-folder-id " ^ rel
  | RecoverStaged -> "recover-staged"
  | CrashBeforeCommit p -> "crash-before-commit " ^ p
  | StaleRecord -> "stale-record"
  | OrphanStagedBody -> "orphan-staged-body"
  | ReclaimStaged -> "reclaim-staged"
  | ClearCache -> "clear-cache"
  | OnSecondary s -> "on-secondary " ^ render_step s
  | ResyncRemote -> "mirror"
  | ResyncScoped { path } -> (
      "mirror" ^ match path with Some p -> " --path " ^ p | None -> "")
  | LocalWrite { path; content } ->
      Printf.sprintf "local-write %s %S" path content
  | LocalMkdir path -> "local-mkdir " ^ path
  | LocalSymlink { path; target } ->
      Printf.sprintf "local-symlink %s -> %s" path target
  | Import { only; exclude; force_rehash } ->
      String.concat " "
        (["import"]
        @ (if force_rehash then ["--force-rehash"] else [])
        @ (if only <> [] then ["--only " ^ String.concat "," only] else [])
        @
        if exclude <> [] then ["--exclude " ^ String.concat "," exclude] else []
        )
  | ExportDir -> "export-dir"

let starts_with prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* Folder ids are minted at random, so a snapshot cannot record one. Each is
   aliased to <folder-N>. The backend dump assigns them by walking the tree, so
   the numbering follows the folder structure rather than the ids; anything an
   IPC response mentions first is numbered on sight. Reset per scenario. *)
let folder_alias : (string, string) Hashtbl.t = Hashtbl.create 16
let alias_index : (string, int) Hashtbl.t = Hashtbl.create 16
let alias_counter = ref 0

let reset_folder_aliases () =
  Hashtbl.reset folder_alias;
  Hashtbl.reset alias_index;
  alias_counter := 0

(* [root_id] and [trash_id] are constants, not minted ids: they are already
   stable and saying so is the point of printing them. *)
let alias_id id =
  if id = Folder.root_id || id = Folder.trash_id then id
  else (
    match Hashtbl.find_opt folder_alias id with
      | Some a -> a
      | None ->
          incr alias_counter;
          let a = Printf.sprintf "<folder-%d>" !alias_counter in
          Hashtbl.add folder_alias id a;
          Hashtbl.add alias_index id !alias_counter;
          a)

(* Backend keys under a folder lead with that folder's id, so listing them in key
   order orders them by a random number. Sorting on this instead puts them in
   alias order, which follows the tree. Zero-padded so <folder-10> does not sort
   before <folder-2>. *)
let sort_key k =
  String.concat "/"
    (List.map
       (fun part ->
         match Hashtbl.find_opt alias_index part with
           | Some i -> Printf.sprintf "%06d" i
           | None -> part)
       (String.split_on_char '/' k))

(* A minted id is 16 lowercase hex characters. Distinguishes one from a name or
   from the [root_id]/[trash_id] constants. *)
let is_minted_id s =
  String.length s = 16
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

(* A reference names a folder by id: ["d:<id>"] or ["f:<id>/<leaf>"]. *)
let alias_ref s =
  let alias_after n =
    let rest = String.sub s n (String.length s - n) in
    match String.index_opt rest '/' with
      | Some i ->
          String.sub s 0 n
          ^ alias_id (String.sub rest 0 i)
          ^ String.sub rest i (String.length rest - i)
      | None -> String.sub s 0 n ^ alias_id rest
  in
  if starts_with "d:" s then alias_after 2
  else if starts_with "f:" s then alias_after 2
  else s

(* Counts, not bytes: byte totals are the test's own payload sizes and would pin
   the snapshot to them without saying anything about the behaviour. *)
let print_gc (s : Gc.stats) =
  Printf.printf "  gc kept %d chunk(s), reclaimed %d\n" s.Gc.chunks_promoted
    s.chunks_reclaimed;
  (* Only under [GcVerify]: an ordinary collection reads nothing, and a row of
     zeros would read as "checked, nothing wrong". *)
  if s.Gc.chunks_verified > 0 || s.Gc.chunks_unreadable > 0 then
    Printf.printf
      "  gc verified %d chunk(s): %d corrupt, %d unreadable, %d cleared\n"
      s.Gc.chunks_verified s.Gc.chunks_corrupt s.Gc.chunks_unreadable
      s.Gc.chunks_cleared

(* Verbatim but for the non-deterministic parts: wall-clock mtimes, journal-key
   cursors, and the filesystem-order [files]/[dirs] arrays. etags and keys are
   deterministic and shown as-is. *)
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
    | ("ref" | "parentRef" | "srcRef"), `String s -> (k, `String (alias_ref s))
    (* A bare "id" in a journal op names a folder. Unlike an etag, it cannot be
       a content hash, so it needs no table lookup to tell the two apart. *)
    | "id", `String s when is_minted_id s -> (k, `String (alias_id s))
    (* A directory's etag is its own folder id. *)
    | "etag", `String s when Hashtbl.mem folder_alias s ->
        (k, `String (alias_id s))
    | "mtime", `Float f -> (k, `String (if f > 0. then "<mtime>" else "<zero>"))
    | "cursor", `String s ->
        (k, `String (if s = "" then "<empty>" else "<cursor>"))
    | "items", `List l ->
        ( k,
          `List
            (List.stable_sort
               (fun a b -> compare (ipc_entry_key a) (ipc_entry_key b))
               (List.map normalize_ipc l)) )
    | k, v -> (k, normalize_ipc v)

let print_ipc label obj =
  (* The label is the request, which names its target by reference. *)
  Printf.printf "  %s -> %s\n"
    (String.concat " " (List.map alias_ref (String.split_on_char ' ' label)))
    (Yojson.Safe.to_string (normalize_ipc (`Assoc obj)))

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
  (* Whole JSON rather than a snapshot: most of it is pids, uptimes and
     paths. *)
  stats : unit -> (string * Yojson.Safe.t) list Lwt.t;
}

(* The real IPC handler, driven directly without a socket: every daemon service
   and the handler run on the one Lwt loop [run_scenario] spins up. *)
let setup_client (module C : Conf.S) root staging_prefix =
  let module Sq = Sync_queue.Make (C) in
  let module F = File.Make (C) (Sq) in
  let module Mf = Manifest.Make (C) in
  let module H = Ipc_handler.Make (C) (F) in
  let module Rp = Replay.Make (C) (F) in
  let module J = Journal.Make (C) in
  let module W = Wal.Make (C) in
  let module L = Layout.Inode.Make (C) in
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
        evict = F.evict;
        restore = F.ensure_cached;
        changed = (fun _ -> ());
        full_resync = (fun () -> Lwt.return_unit);
        status_fields = (fun () -> []);
        (* Frontends name themselves in their stats, as fuse and file_provider
           do, so the report can say whose numbers these are. *)
        stats_fields = (fun () -> [("frontend", `String "test")]);
        on_stop = (fun () -> ());
      }
  in
  Sq.start
    ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
    ~on_cursor:(fun ~entry_key:_ -> ())
    ~on_upload_done:(fun ~key:_ ->
      (* Mirror the daemons: nudge cache-cap enforcement after each upload. *)
      F.enforce_chunk_cap ());
  let staging_seq = ref 0 in
  let mark_time = ref 0. in
  (* Where the body of a file's chunk [index] lives in the chunk store, for the
     steps that damage it behind the daemon's back. *)
  (* The cache file backing stored chunk [index] — the whole group it falls in,
     which is one chunk only when the cache chunk size matches the stored one. *)
  let cached_chunk_path k index =
    let+ resolved = F.resolve k in
    let group =
      match resolved with
        | Some (`Published m) -> (
            match Mf.group_at m index with
              | Some g -> g
              | None -> failwith "no such chunk")
        | _ -> failwith "no published manifest"
    in
    Cache_layout.chunk_path ~cache_root:C.cache_root ~domain_name:C.domain_name
      (Chunk_group.key group)
  in
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
  let action ?src ?staging ?arg ?target act path =
    request
      ([("action", `String act); ("path", `String path)]
      @ (match src with Some s -> [("src", `String s)] | None -> [])
      @ (match arg with Some s -> [("arg", `String s)] | None -> [])
      @ (match target with Some s -> [("target", `String s)] | None -> [])
      @ match staging with Some s -> [("staging", `String s)] | None -> [])
  in
  let must obj =
    if not (response_ok obj) then failwith ("IPC error: " ^ response_error obj)
  in
  let must_action ?src ?staging ?arg ?target act path =
    let+ obj = action ?src ?staging ?arg ?target act path in
    must obj
  in
  (* Backend damage for integrity scenarios: resolve a chunk key from the local
     sidecar, then delete or overwrite the remote object behind the daemon's
     back. *)
  let remote_chunk_key path index =
    let* m = F.read_manifest (key path) in
    match m with
      | Some m ->
          Lwt.return
            (C.chunk_prefix
            ^ Chunk_layout.relative_path
                (Chunk_table.key m.Manifest.chunks index))
      | _ -> failwith ("no clean sidecar for " ^ path)
  in
  (* The member, not just its module: damaging a file behind the store's back
     needs to know where the store keeps it. *)
  let damage (m : Backend.member) =
    let (module B : Backend.S) = m.Backend.backend in
    function
    | DeleteRemoteChunk { path; index } ->
        let* ck = remote_chunk_key path index in
        B.delete ~key:ck ()
    | CorruptRemoteChunk { path; index } ->
        let* ck = remote_chunk_key path index in
        B.put ~key:ck ~data:(Chunk.of_string "garbage") ()
    (* Same length, different bytes: what a size comparison cannot see. *)
    | ScrambleRemoteChunk { path; index } ->
        let* ck = remote_chunk_key path index in
        let* data = B.get ~key:ck () in
        B.put ~key:ck
          ~data:
            (Chunk.of_string
               (String.map
                  (fun c -> Char.chr ((Char.code c + 1) land 0xff))
                  (Chunk.to_string data)))
          ()
    (* Straight at the file, where [ScrambleRemoteChunk] goes through the
       store's own [put] and is caught on the way in. This is what bit rot looks
       like: the bytes changed under a store that was never asked to write them,
       and only a pass that reads them back can tell. *)
    | ScrambleBackendFile { path; index } ->
        let* ck = remote_chunk_key path index in
        let root =
          match m.Backend.local_path with
            | Some root -> root
            | None -> failwith "scramble-backend-file: not a local store"
        in
        let p = Filename.concat root ck in
        let ic = open_in_bin p in
        let len = in_channel_length ic in
        let body = really_input_string ic len in
        close_in ic;
        let oc = open_out_bin p in
        output_string oc
          (String.map (fun c -> Char.chr ((Char.code c + 1) land 0xff)) body);
        close_out oc;
        Lwt.return_unit
    | DeleteRemoteManifest p -> (
        let* bk = L.manifest_key (key p) in
        match bk with
          | None -> failwith ("no backend key for " ^ p)
          | Some bk -> B.delete ~key:bk ())
    | s -> failwith ("not a backend-damage step: " ^ render_step s)
  in
  let mkdir_p d =
    let rec loop d =
      if not (Sys.file_exists d) then begin
        loop (Filename.dirname d);
        Unix.mkdir d 0o755
      end
    in
    loop d
  in
  let local_staging : string option ref = ref None in
  let get_or_create_staging () =
    match !local_staging with
      | Some d -> d
      | None ->
          incr staging_seq;
          let d =
            Filename.concat root
              (Printf.sprintf "local-%s%d" staging_prefix !staging_seq)
          in
          Unix.mkdir d 0o755;
          local_staging := Some d;
          d
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
    | Symlink { path; target } ->
        (* Print a rejection instead of failing: symlink creation is expected
           to be refused when the domain policy is not [`Keep]. *)
        let+ obj = action ~target "symlink" (key path) in
        if not (response_ok obj) then
          Printf.printf "  symlink %s: rejected (%s)\n" path
            (response_error obj)
    | Mkdir p -> must_action "mkdir" (key p ^ "/")
    | Rmdir p -> must_action "rmdir" (key p ^ "/")
    | Rename { src; dst } -> must_action ~src:(key src) "rename" (key dst)
    | Delete p -> must_action "delete" (key p)
    | Evict p -> must_action "evict" ("/" ^ p)
    | EnforceCache -> F.enforce_chunk_cap ()
    | Restore p -> must_action "restore" ("/" ^ p)
    | RevertVersion { path; version } ->
        must_action ?arg:version "revert" ("/" ^ path)
    | Close p -> F.close (key p)
    | ReadRange { path; offset; len } ->
        let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout len in
        let* n = F.read (key path) buf ~offset:(Int64.of_int offset) in
        let bytes = Bytes.create n in
        for i = 0 to n - 1 do
          Bytes.set bytes i (Bigarray.Array1.get buf i)
        done;
        Printf.printf "  read %s [%d,%d) = %S\n" path offset (offset + len)
          (Bytes.to_string bytes);
        Lwt.return_unit
    | FetchRange { path; offset; len } ->
        (* Somewhere outside the cache and the data dir, so the destination is
           not mistaken for daemon state. The system hands the extension a fresh
           path per range; one reused path shows the same thing here. *)
        let dst = Filename.concat (Filename.dirname C.cache_root) "range.out" in
        let* () = Fs_util.unlink_quiet dst in
        let* n = F.fetch_range (key path) ~dst_path:dst ~offset ~length:len in
        let served =
          let ic = open_in_bin dst in
          let size = in_channel_length ic in
          seek_in ic (min offset size);
          let s = really_input_string ic (max 0 (min n (size - offset))) in
          close_in ic;
          s
        in
        (* The file length is the point of the range landing at its own offset:
           everything before it is a hole, so the file stops where the range
           does rather than starting at zero. *)
        Printf.printf "  fetch-range %s [%d,%d) served=%d file-size=%d = %S\n"
          path offset (offset + len) n (Unix.stat dst).Unix.st_size served;
        Lwt.return_unit
    | WriteAt { path; offset; content } ->
        let len = String.length content in
        let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout len in
        for i = 0 to len - 1 do
          Bigarray.Array1.set buf i content.[i]
        done;
        let* (_ : int) = F.write (key path) buf ~offset:(Int64.of_int offset) in
        Lwt.return_unit
    | Truncate { path; size } -> F.truncate (key path) (Int64.of_int size)
    | Stat p ->
        let+ obj = action "stat" (key p) in
        if response_ok obj then
          Printf.printf "  stat %s: %s\n" p
            (Yojson.Safe.to_string (`Assoc (List.remove_assoc "mtime" obj)))
        else Printf.printf "  stat %s: %s\n" p (response_error obj)
    | ShowNames p ->
        (* The entry names a readdir serves for this directory. *)
        let prefix = if p = "" then C.domain_prefix else key p ^ "/" in
        let+ files, dirs = F.list_children ~prefix in
        let names =
          List.map
            (fun (e : Backend.file_entry) -> Filename.basename e.Backend.key)
            files
          @ List.map (fun (d, _) -> d ^ "/") dirs
        in
        Printf.printf "  names %s = [%s]\n"
          (if p = "" then "/" else p)
          (String.concat " " (List.sort compare names))
    | ShowChunkCache ->
        let+ chunks, bytes = F.chunk_stats () in
        Printf.printf "  chunk-cache chunks=%d bytes=%d\n" chunks bytes
    | ShowStaged ->
        let count dir =
          let rec walk dir =
            if not (Sys.file_exists dir) then 0
            else
              Array.fold_left
                (fun n name ->
                  let p = Filename.concat dir name in
                  if Sys.is_directory p then n + walk p else n + 1)
                0 (Sys.readdir dir)
          in
          walk (dir ~cache_root:C.cache_root C.domain_name)
        in
        Printf.printf "  staged manifests=%d bodies=%d\n"
          (count Cache_layout.staged_manifests_dir)
          (count Cache_layout.staged_chunks_dir
          + count Cache_layout.staged_whole_dir);
        Lwt.return_unit
    | ShowChunks p ->
        let k = key p in
        let* resolved = F.resolve k in
        let desc =
          match resolved with
            | Some (`Staged (st, _)) ->
                (* S = written locally, I = still inherited from the published
                   manifest, Z = a hole from a grow (zeros, no disk). *)
                Printf.sprintf "staged size=%Ld slots=[%s]" st.Manifest.s_size
                  (String.concat ""
                     (Array.to_list
                        (Array.map
                           (function
                             | Manifest.Staged _ -> "S"
                             | Manifest.Inherit -> "I"
                             | Manifest.Zero -> "Z")
                           st.Manifest.s_slots)))
            | Some (`Published m) ->
                Printf.sprintf "published size=%Ld chunks=%d" m.Manifest.size
                  (Chunk_table.count m.Manifest.chunks)
            | None -> "no manifest"
        in
        let* local, total = F.chunk_residency k in
        Printf.printf "  chunks %s %s cached=%d/%d\n" p desc local total;
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
        Printf.printf "  expire %s -> %d version(s), %d journal entr(ies)\n"
          selector s.Expire.versions_deleted s.journal_deleted
    | PurgeTrashed path -> (
        let module E = Expire.Make (C) in
        let+ outcome = E.purge_trashed ~path () in
        match outcome with
          | `Not_in_trash -> Printf.printf "  purge %s -> not in trash\n" path
          | `Purged n -> Printf.printf "  purge %s -> %d object(s)\n" path n)
    | Gc ->
        let module G = Gc.Make (C) in
        let+ s = G.run () in
        print_gc s
    | GcVerify ->
        let module G = Gc.Make (C) in
        let* s = G.run ~verify:true () in
        print_gc s;
        (* The collection just changed what is marked. *)
        let module Cor = Corruption.Make (C) in
        Cor.invalidate ();
        Lwt.return_unit
    | GcMark ->
        (* Stopped at the phase boundary rather than after a duration, so a
           scenario can act on a half-collected store deterministically. *)
        let module G = Gc.Make (C) in
        let* session = G.start () in
        let rec until_closing () =
          if G.phase session <> "marking" then Lwt.return_unit
          else
            let* outcome = G.step ~units:64 session in
            match outcome with
              | `Done -> Lwt.return_unit
              | `More -> until_closing ()
        in
        let* () = until_closing () in
        let s = G.stats session in
        (* The lock goes back, not the collection: the next step picks it up from
           the marker, which is what a separate invocation would do. *)
        let+ () = G.release session in
        Printf.printf "  gc marked %d root(s), %d chunk(s) kept\n"
          s.Gc.roots_marked s.chunks_promoted
    | GcClose ->
        let module G = Gc.Make (C) in
        let+ s = G.run () in
        print_gc s
    | GcAbort ->
        let module G = Gc.Make (C) in
        let+ s = G.abort () in
        (* Moved back, not kept: what marking had already moved across is kept
           too, so this is the count that shrinks as a mark gets further along. *)
        Printf.printf "  gc abandoned, %d chunk(s) moved back\n"
          s.Gc.chunks_promoted
    | Drain ->
        let rec wait () =
          if Sq.pending () = 0 then Lwt.return_unit
          else
            let* () = Lwt.pause () in
            wait ()
        in
        let* () = wait () in
        (* Move past the current ms so the next journal entry key is distinct. *)
        Lwt_unix.sleep 0.002
    | Uploads state ->
        Sq.set_paused (state = `Paused);
        Lwt.return_unit
    (* One pass of the poller's algorithm without its timer. Nothing here is
       presenting a mount, so no changed key has anywhere to go. *)
    | Sync ->
        let+ (_ : int) = Rp.apply_foreign ~on_changed:(fun _ -> ()) () in
        ()
    | ( DeleteRemoteChunk _ | CorruptRemoteChunk _ | ScrambleRemoteChunk _
      | ScrambleBackendFile _ | DeleteRemoteManifest _ ) as s ->
        damage (List.hd C.members) s
    | ListCorrupted ->
        let module Cor = Corruption.Make (C) in
        let+ report = Cor.list () in
        let entries = List.sort compare report.Corruption.entries in
        (* A count first, so a listing is visible even when it finds nothing and
           two of them in one scenario cannot be read as one. *)
        Printf.printf "  corrupted: %d\n%!" (List.length entries);
        List.iter
          (fun (e : Corruption.entry) ->
            Printf.printf "    %s on %s\n%!" e.Corruption.chunk_key
              e.Corruption.store)
          entries;
        List.iter
          (fun name -> Printf.printf "    unchecked store %s\n%!" name)
          report.Corruption.unverified
    | RequestVerify ->
        let+ answers =
          Lwt_list.map_s
            (fun (m : Backend.member) ->
              let (module B : Backend.S) = m.Backend.backend in
              let+ a = B.verify_all ~chunk_prefix:C.chunk_prefix () in
              (m.Backend.name, a))
            C.members
        in
        List.iter
          (fun (name, a) ->
            Printf.printf "  %s: %s\n%!" name
              (match a with
                | `Queued n -> Printf.sprintf "queued %d" n
                | `Unsupported -> "unsupported"))
          answers
    | RescanCorrupted ->
        let module Cor = Corruption.Make (C) in
        Cor.invalidate ();
        Lwt.return_unit
    | Repair ->
        let module Rp = Repair.Make (C) in
        let+ s =
          Rp.run
            ~on_start:(fun ~total ->
              Printf.printf "  repair: %d marked\n%!" total)
            ~on_chunk:(fun ~done_ ~total ~chunk_key ~store outcome ->
              Printf.printf "  [%d/%d] %s\n%!" done_ total
                (Repair.describe ~chunk_key ~store outcome))
            ()
        in
        Printf.printf
          "  repair: %d checked, %d repaired, %d cleared, %d lost\n%!"
          s.Repair.checked s.Repair.repaired s.Repair.cleared
          s.Repair.unrepairable
    | OnSecondary s -> (
        match C.members with
          | _ :: dst :: _ -> damage dst s
          | _ -> failwith "OnSecondary: no secondary backend configured")
    | LocalWrite { path; content } ->
        let staging = get_or_create_staging () in
        let abs = Filename.concat staging path in
        mkdir_p (Filename.dirname abs);
        write_file abs content;
        Lwt.return_unit
    | LocalMkdir path ->
        mkdir_p (Filename.concat (get_or_create_staging ()) path);
        Lwt.return_unit
    | LocalSymlink { path; target } ->
        let staging = get_or_create_staging () in
        let abs = Filename.concat staging path in
        mkdir_p (Filename.dirname abs);
        Unix.symlink target abs;
        Lwt.return_unit
    | Import { only; exclude; force_rehash } ->
        let src =
          match !local_staging with
            | Some d -> d
            | None -> get_or_create_staging ()
        in
        local_staging := None;
        let module I = Import.Make (C) in
        let+ summary =
          I.run ~only ~exclude ~force_rehash ~src
            ~on_dir:(fun ~rel -> Printf.printf "  mkdir %s\n" rel)
            ~on_file:(fun ~rel status ->
              match status with
                | Import.Imported size ->
                    Printf.printf "  imported %s (%Ld bytes)\n" rel size
                | Import.Skipped_exists ->
                    Printf.printf "  skip %s (exists)\n" rel
                | Import.Skipped_symlink ->
                    Printf.printf "  skip %s (symlink)\n" rel
                | Import.Failed msg -> Printf.printf "  failed %s: %s\n" rel msg)
            ()
        in
        Printf.printf "  import: %d imported, %d skipped, %d symlinks skipped\n"
          summary.Import.imported summary.Import.skipped
          summary.Import.skipped_symlinks
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
                  | Export.Exported -> "assembled"
                  | Export.Exported_symlink -> "symlink"
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
              let abs = Filename.concat dst r in
              let* kind = Fs_util.lstat_kind abs in
              match kind with
                | `Dir -> dump r
                | `Symlink target ->
                    Printf.printf "  exported-symlink %s -> %s\n" r target;
                    Lwt.return_unit
                | _ ->
                    Printf.printf "  exported-file %s = %S\n" r (read_file abs);
                    Lwt.return_unit)
            (List.sort compare names)
        in
        dump ""
    | (ResyncRemote | ResyncScoped _) as s ->
        let module M = Mirror.Make (C) in
        let scope =
          match s with
            | ResyncScoped { path = Some rel; _ } -> `Path rel
            | _ -> `All
        in
        let+ dests = M.resync ~scope () in
        List.iteri
          (fun i (d : Mirror.dest_stats) ->
            (* Only counts: copied keys carry non-deterministic folder ids /
               version timestamps, and the aliased backend dump already shows the
               resulting state. Bytes are omitted (manifests embed mtimes). *)
            (* Numbered from the source, which is destination zero. *)
            Printf.printf "  resync backend #%d: %d checked, %d copied\n"
              (i + 2) d.Mirror.checked d.Mirror.copied)
          dests
    | StageWrite { path; content } ->
        (* Staged edits with no upload queued, the way a writer leaves a file
           between write and close. *)
        let k = key path in
        let* () = F.truncate k 0L in
        let len = String.length content in
        let buf =
          Bigarray.Array1.create Bigarray.char Bigarray.c_layout (max 1 len)
        in
        String.iteri (fun i c -> Bigarray.Array1.set buf i c) content;
        let* (_ : int) = F.write k (Bigarray.Array1.sub buf 0 len) ~offset:0L in
        Lwt.return_unit
    | DeleteCachedChunk { path; index } ->
        let* () = F.ensure_cached (key path) in
        let* p = cached_chunk_path (key path) index in
        Lwt.catch (fun () -> Lwt_unix_retry.unlink p) (fun _ -> Lwt.return_unit)
    | ForgetFolderId rel ->
        let marker =
          Filename.concat
            (Filename.concat
               (Cache_layout.manifests_dir ~cache_root:C.cache_root
                  C.domain_name)
               (Name_escape.encode_key rel))
            Folder_ids.marker_name
        in
        Lwt.catch
          (fun () -> Lwt_unix_retry.unlink marker)
          (fun _ -> Lwt.return_unit)
    | RecoverStaged -> Rp.reconcile ()
    | CrashBeforeCommit path ->
        let k = key path in
        let* () = F.upload k in
        let* m = F.read_manifest k in
        let size = match m with Some m -> m.Manifest.size | None -> 0L in
        let ek = J.entry_key () in
        let* () = W.record ek [`Put (F.rel_key k, size)] in
        W.advance ek Wal.Executed
    | StaleRecord ->
        let dir =
          Filename.concat
            (Filename.concat C.data_dir "journal-pending")
            C.domain_name
        in
        mkdir_p dir;
        write_file
          (Filename.concat dir (Journal.Entry_key.to_string (J.entry_key ())))
          (Journal.encode [`Put ("gone.zip", 42L)]);
        Lwt.return_unit
    | OrphanStagedBody ->
        (* What a crash between staging a body and writing the manifest that
           names it leaves behind, in both body trees. *)
        List.iter
          (fun dir ->
            let dir = dir ~cache_root:C.cache_root C.domain_name in
            mkdir_p dir;
            write_file (Filename.concat dir "orphan-uuid") "leaked bytes")
          [Cache_layout.staged_chunks_dir; Cache_layout.staged_whole_dir];
        Lwt.return_unit
    | ReclaimStaged -> F.reclaim_staged_orphans ()
    | ClearCache ->
        Cache_layout.clear ~cache_root:C.cache_root ~domain_name:C.domain_name
  in
  let drain () = Sq.drain () in
  let stop () = Lwt.return_unit in
  let get_str obj k =
    match List.assoc_opt k obj with Some (`String s) -> Some s | _ -> None
  in
  (* One list now, each entry saying which it is. *)
  let split_items obj =
    let items =
      match List.assoc_opt "items" obj with Some (`List l) -> l | _ -> []
    in
    List.partition_map
      (function
        | `Assoc f ->
            let key = Option.value ~default:"" (get_str f "key") in
            if get_str f "kind" = Some "dir" then Either.Left key
            else Either.Right key
        | _ -> Either.Right "")
      items
  in
  let dump_tree () =
    let files = ref [] in
    let rec walk prefix =
      let* obj = action "list_dir" prefix in
      must obj;
      let dirs, entries = split_items obj in
      let entries = List.map F.rel_key entries in
      let* () =
        Lwt_list.iter_s
          (fun rel ->
            let* st = action "stat" (key rel) in
            let uploaded = List.assoc_opt "isUploaded" st = Some (`Bool true) in
            let etag = Option.value ~default:"" (get_str st "etag") in
            let size =
              match List.assoc_opt "size" st with Some (`Int n) -> n | _ -> -1
            in
            let+ local, total = F.chunk_residency (key rel) in
            Printf.printf "  f %s size=%d cached=%d/%d uploaded=%b etag=%s\n"
              rel size local total uploaded etag;
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
  (* Whole-file content through the read path itself — the same one FUSE and the
     frontends use — so a snapshot shows what a reader would actually get. A
     failed read (e.g. an unrepairable evicted file) is part of the snapshot, not
     a reason to abort the remaining files' contents. *)
  let read_whole rel size =
    let buf =
      Bigarray.Array1.create Bigarray.char Bigarray.c_layout (max 1 size)
    in
    let out = Buffer.create size in
    let rec go offset =
      let* n =
        F.read (key rel)
          (Bigarray.Array1.sub buf 0 (max 1 (size - offset)))
          ~offset:(Int64.of_int offset)
      in
      if n <= 0 then Lwt.return_unit
      else (
        for i = 0 to n - 1 do
          Buffer.add_char out (Bigarray.Array1.get buf i)
        done;
        if offset + n >= size then Lwt.return_unit else go (offset + n))
    in
    let+ () = if size <= 0 then Lwt.return_unit else go 0 in
    Buffer.contents out
  in
  let dump_contents files =
    Lwt_list.iter_s
      (fun rel ->
        let* st = action "stat" (key rel) in
        match get_str st "symlinkTarget" with
          | Some target ->
              Printf.printf "  %s -> %s\n" rel target;
              Lwt.return_unit
          | None ->
              let size =
                match List.assoc_opt "size" st with
                  | Some (`Int n) -> n
                  | _ -> 0
              in
              Lwt.catch
                (fun () ->
                  let+ content = read_whole rel size in
                  Printf.printf "  %s = %S\n" rel content)
                (fun exn ->
                  Printf.printf "  %s = <unavailable: %s>\n" rel
                    (Printexc.to_string exn);
                  Lwt.return_unit))
      files
  in
  let string_of_state = function
    | Wal.Intent -> "intent"
    | Wal.Prepared -> "prepared"
    | Wal.Executed -> "executed"
  in
  let dump_pending () =
    let+ pending = W.list () in
    List.iter
      (fun (_, (r : Wal.record)) ->
        Printf.printf "  pending %s [%s]\n"
          (string_of_state r.Wal.state)
          (String.concat "; " (List.map render_op r.Wal.ops)))
      pending
  in
  (* Recursive list_dir (per directory) then the flat list_all working-set view —
     the actual IPC responses, normalized. *)
  (* Walked by reference rather than by key: that is how the File Provider asks,
     and it is the only way the id-to-path resolution behind it gets exercised.
     [dump_tree] still walks by key, so both ways of naming an item stay
     covered. *)
  let by_ref act r = request [("action", `String act); ("ref", `String r)] in
  let dir_refs obj =
    let items =
      match List.assoc_opt "items" obj with Some (`List l) -> l | _ -> []
    in
    List.filter_map
      (function
        | `Assoc f when get_str f "kind" = Some "dir" -> get_str f "ref"
        | _ -> None)
      items
  in
  let dump_listing () =
    let rec walk r =
      let* obj = by_ref "list_dir" r in
      must obj;
      print_ipc (Printf.sprintf "list_dir %s" r) obj;
      Lwt_list.iter_s walk (List.sort compare (dir_refs obj))
    in
    let* () = walk "root" in
    let* obj = by_ref "list_all" "root" in
    must obj;
    print_ipc "list_all root" obj;
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
  let stats () =
    let+ obj = action "stats" "" in
    must obj;
    obj
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
    stats;
  }

let dump_backend_at ~backend_root ~domain_prefix ~chunk_prefix ~journal_prefix
    ~versions_prefix ~cursor_key =
  let (module B : Backend.S) =
    Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some backend_root)
  in
  let rel_key k =
    let pfx = String.length domain_prefix in
    if String.length k > pfx then String.sub k pfx (String.length k - pfx)
    else k
  in
  let* entries = B.list_prefix ~prefix:"" () in
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
  (* Folder ids are minted at random, so a snapshot cannot record one. Each is
     aliased to <folder-N>, numbered by walking the tree from the root and taking
     each folder's children in name order — a property of the tree rather than of
     the ids, so the numbering holds even though the ids differ every run. *)
  let* markers =
    Lwt_list.filter_map_s
      (fun (e : Backend.file_entry) ->
        if
          starts_with domain_prefix e.key
          && not
               (String.length e.key > 0 && e.key.[String.length e.key - 1] = '/')
        then
          let+ data = B.get ~key:e.key () in
          match Folder.marker_of_string (Chunk.to_string data) with
            | Some m ->
                let rel = rel_key e.key in
                let parent =
                  match String.index_opt rel '/' with
                    | Some i -> String.sub rel 0 i
                    | None -> rel
                in
                Some (parent, m.Folder.name, m.Folder.id)
            | None -> None
        else Lwt.return_none)
      entries
  in
  let rec number_under parent =
    List.iter
      (fun (_, _, id) ->
        if not (Hashtbl.mem folder_alias id) then (
          ignore (alias_id id);
          number_under id))
      (List.sort compare (List.filter (fun (p, _, _) -> p = parent) markers))
  in
  number_under Folder.root_id;
  number_under Folder.trash_id;
  (* Anything the walk did not reach — a marker whose parent is gone — still
     needs a stable name, taken in name order. *)
  List.iter
    (fun (n, _, id) ->
      if not (Hashtbl.mem folder_alias id) then ignore (alias_id id))
    (List.sort compare (List.map (fun (_, n, i) -> (n, n, i)) markers));
  let entries =
    List.stable_sort
      (fun (a : Backend.file_entry) (b : Backend.file_entry) ->
        compare (sort_key a.key) (sort_key b.key))
      entries
  in
  (* A rel key under a folder namespace leads with that folder's id. *)
  let alias_rel rel =
    match String.index_opt rel '/' with
      | Some i -> (
          let head = String.sub rel 0 i in
          match Hashtbl.find_opt folder_alias head with
            | Some a -> a ^ String.sub rel i (String.length rel - i)
            | None -> rel)
      | None -> rel
  in
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
  (* A collection in progress: the space chunks are on their way out of, and the
     marker naming the phase. Shown rather than hidden — a snapshot taken
     mid-collection is meant to say which space each chunk is in. The lock beside
     the marker is not shown: it is an empty file whose only content is who holds
     it, and that is never this. *)
  let from_prefix = Chunk_space.from_prefix ~chunk_prefix in
  let gc_marker = Chunk_space.marker_key ~chunk_prefix in
  (* Folder ids are deterministic (the RNG is seeded per scenario), so the dump
     prints them raw: a reviewer can trace [file <id>/<hash>] back to the
     [folder … -> <id>] marker that named it. *)
  Lwt_list.iter_s
    (fun (e : Backend.file_entry) ->
      (* Internal prefixes have no meaningful directories; ignore the empty-dir
         markers the local backend surfaces where S3 would list nothing. *)
      if
        is_marker e.key
        && (starts_with chunk_prefix e.key
           || starts_with versions_prefix e.key
           || starts_with journal_prefix e.key)
      then Lwt.return_unit
      else if e.key = gc_marker ^ ".lock" then Lwt.return_unit
      else if e.key = gc_marker then
        let+ data = B.get ~key:e.key () in
        (* The marker's phase, read straight from its body. The snapshot pins
           the phase name, so a change to how the marker is written shows up as
           "unreadable" in the diff rather than passing quietly. *)
        Printf.printf "  collecting: %s\n"
          (match Yojson.Safe.from_string (Chunk.to_string data) with
            | `Assoc kvs -> (
                match List.assoc_opt "phase" kvs with
                  | Some (`String p) -> p
                  | _ -> "unreadable")
            | _ | (exception _) -> "unreadable")
      else if starts_with from_prefix e.key then
        if is_marker e.key then Lwt.return_unit
        else (
          Printf.printf "  chunk(going) %s size=%d\n" (Filename.basename e.key)
            e.size;
          Lwt.return_unit)
      else if starts_with chunk_prefix e.key then (
        (* The key, without the shard directory holding it: what a chunk is
           named matters here, where it lives is {!Chunk_layout}'s business. *)
        Printf.printf "  chunk %s size=%d\n" (Filename.basename e.key) e.size;
        Lwt.return_unit)
      else if starts_with journal_prefix e.key then
        let+ data = B.get ~key:e.key () in
        let ops = Journal.decode (Chunk.to_string data) in
        Printf.printf "  journal %s = %s\n"
          (entry_alias (Filename.basename e.key))
          (String.concat "; " (List.map render_op ops))
      else if e.key = cursor_key then
        let+ data = B.get ~key:e.key () in
        Printf.printf "  cursor = %s\n"
          (entry_alias (String.trim (Chunk.to_string data)))
      else if starts_with versions_prefix e.key then (
        match Versioning.parse ~versions_prefix e.key with
          | Some (rel, _) ->
              let n =
                Option.value ~default:0 (Hashtbl.find_opt version_alias e.key)
              in
              let+ data = B.get ~key:e.key () in
              let name, desc =
                match Manifest.of_string (Chunk.to_string data) with
                  | m ->
                      ( Manifest.recorded_name m,
                        Printf.sprintf "manifest size=%Ld chunks=%d"
                          m.Manifest.size
                          (Chunk_table.count m.Manifest.chunks) )
                  | exception _ -> (rel, "raw")
              in
              Printf.printf "  version %s [%s]#%d = %s\n" name rel n desc
          | None ->
              Printf.printf "  other %s size=%d\n" e.key e.size;
              Lwt.return_unit)
      else if starts_with domain_prefix e.key then (
        let rel = rel_key e.key in
        if String.length e.key > 0 && e.key.[String.length e.key - 1] = '/' then
          (* Empty-namespace directories are a local-backend artifact (S3 has no
             such object); skip them. *)
          Lwt.return_unit
        else
          let+ data = B.get ~key:e.key () in
          match Folder.marker_of_string (Chunk.to_string data) with
            | Some m ->
                if starts_with (domain_prefix ^ Folder.trash_id ^ "/") e.key
                then
                  Printf.printf "  trash %s -> %s\n" m.Folder.name
                    (alias_id m.Folder.id)
                else
                  Printf.printf "  folder %s [%s] -> %s\n" m.Folder.name
                    (alias_rel rel) (alias_id m.Folder.id)
            | None -> (
                match Manifest.of_string (Chunk.to_string data) with
                  | { symlink = Some target; _ } as m ->
                      Printf.printf "  symlink %s [%s] -> %s\n"
                        (Manifest.recorded_name m) (alias_rel rel) target
                  | m ->
                      Printf.printf
                        "  file %s [%s] = manifest size=%Ld chunks=%d h1=%s \
                         h2=%s\n"
                        (Manifest.recorded_name m) (alias_rel rel)
                        m.Manifest.size
                        (Chunk_table.count m.Manifest.chunks)
                        m.Manifest.h1 m.Manifest.h2;
                      let table = m.Manifest.chunks in
                      for i = 0 to Chunk_table.count table - 1 do
                        Printf.printf "    chunk#%d %s size=%d\n" i
                          (Chunk_table.key table i) (Chunk_table.len table i)
                      done
                  | exception _ ->
                      Printf.printf "  file %s = raw size=%d\n" (alias_rel rel)
                        e.size))
      else if Chunk_layout.is_marker_key e.key then (
        (* The chunk it accuses, not the marker's own path, and never its size:
           the body carries the moment it was found, whose float renders to a
           different width from one run to the next. *)
        Printf.printf "  corrupted %s\n"
          (Chunk_layout.chunk_key_of_marker e.key);
        Lwt.return_unit)
      else (
        Printf.printf "  other %s size=%d\n" e.key e.size;
        Lwt.return_unit))
    entries

(* Seed the RNG so [Folder.new_id] is deterministic within a scenario: folder ids
   are then stable across runs, which keeps both the backend-key ordering and the
   snapshots reproducible (and makes the real ids readable in the dump). Each
   scenario re-seeds so it stays independent of the ones before it. *)
(* Ids are random every run; the snapshot aliases them instead of fixing them,
   so what resets between scenarios is the alias numbering. *)
let reset_ids () = reset_folder_aliases ()

let run_scenario ?(versioning = false) ?(symlink_policy = `Keep)
    ({ name; steps } : scenario) =
  reset_ids ();
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
    let domain_prefix = "tsync/test/manifests/"
    let chunk_prefix = "tsync/test/chunks/"
    let versions_prefix = "tsync/test/versions/"
    let journal_prefix = "tsync/test/journal/"
    let cursor_key = "tsync/test/cursor"
    let shares_prefix = "tsync/shares/"

    (* Two mains, so a write fans out over both and [ResyncRemote] has a second
       store to copy into. *)
    let members =
      [
        Backend.member ~name:"backend" ~backend_type:"local"
          ~config:[("path", backend_root)]
          ~local_path:backend_root
          (Backend.make ~backend_type:"local" ~get_field:(fun _ ->
               Some backend_root));
        Backend.member ~name:"backend2" ~backend_type:"local"
          ~config:[("path", backend2_root)]
          ~local_path:backend2_root
          (Backend.make ~backend_type:"local" ~get_field:(fun _ ->
               Some backend2_root));
      ]

    let store =
      Domain_store.make ~targets:[] ~archives:[]
        ~mains:
          (List.map
             (fun (m : Backend.member) ->
               {
                 Domain_store.name = m.Backend.name;
                 backend = m.Backend.backend;
               })
             members)

    let cache_root = Filename.concat root "cache"
    let data_dir = Filename.concat root "data"
    let socket_path = Filename.concat root "tsync.sock"
    let max_uploads = 4
    let max_chunk_buffers = 4
    let max_downloads = 8
    let chunk_size = Some chunk_size
    let cache_chunk_size = Some cache_chunk_size

    let max_cache =
      match Sys.getenv_opt "TSYNC_MAX_CACHE" with
        | Some s -> Conf_parsing.parse_size s
        | None -> None

    let symlink_policy = symlink_policy
    let read_only = false
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
        content fetch fails (e.g. an unrepairable evicted file). *)
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
  reset_ids ();
  Printf.printf "=== %s\n" name;
  List.iter
    (fun s ->
      Printf.printf "  %s: %s\n"
        (match s with A _ -> "A" | B _ -> "B")
        (render_step (match s with A s | B s -> s)))
    steps;
  let root = Filename.temp_dir "tsync-test-2" "" in
  let backend_root = Filename.concat root "backend" in
  let shared_members =
    [
      Backend.member ~name:"backend" ~backend_type:"local"
        ~config:[("path", backend_root)]
        ~local_path:backend_root
        (Backend.make ~backend_type:"local" ~get_field:(fun _ ->
             Some backend_root));
    ]
  in
  let module Ca = struct
    let versioning = versioning
    let client_name = "Client A"
    let domain_name = "test"
    let domain_prefix = "tsync/test/manifests/"
    let chunk_prefix = "tsync/test/chunks/"
    let versions_prefix = "tsync/test/versions/"
    let journal_prefix = "tsync/test/journal/"
    let cursor_key = "tsync/test/cursor"
    let shares_prefix = "tsync/shares/"
    let members = shared_members
    let store = (List.hd members).Backend.backend
    let cache_root = Filename.concat root "cache-a"
    let data_dir = Filename.concat root "data-a"
    let socket_path = Filename.concat root "tsync-a.sock"
    let max_uploads = 4
    let max_chunk_buffers = 4
    let max_downloads = 8
    let chunk_size = Some chunk_size
    let cache_chunk_size = Some cache_chunk_size

    let max_cache =
      match Sys.getenv_opt "TSYNC_MAX_CACHE" with
        | Some s -> Conf_parsing.parse_size s
        | None -> None

    let symlink_policy = `Keep
    let read_only = false
  end in
  let module Cb = struct
    let versioning = versioning
    let client_name = "Client B"
    let domain_name = "test"
    let domain_prefix = "tsync/test/manifests/"
    let chunk_prefix = "tsync/test/chunks/"
    let versions_prefix = "tsync/test/versions/"
    let journal_prefix = "tsync/test/journal/"
    let cursor_key = "tsync/test/cursor"
    let shares_prefix = "tsync/shares/"
    let members = shared_members
    let store = (List.hd members).Backend.backend
    let cache_root = Filename.concat root "cache-b"
    let data_dir = Filename.concat root "data-b"
    let socket_path = Filename.concat root "tsync-b.sock"
    let max_uploads = 4
    let max_chunk_buffers = 4
    let max_downloads = 8
    let chunk_size = Some chunk_size
    let cache_chunk_size = Some cache_chunk_size

    let max_cache =
      match Sys.getenv_opt "TSYNC_MAX_CACHE" with
        | Some s -> Conf_parsing.parse_size s
        | None -> None

    let symlink_policy = `Keep
    let read_only = false
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

let run ?versioning ?symlink_policy scenarios =
  List.iter (run_scenario ?versioning ?symlink_policy) scenarios

let run_two_client_scenarios ?versioning scenarios =
  List.iter (run_two_client_scenario ?versioning) scenarios

let make_conf ?(versioning = false) ~client_name ~backend_root ~cache_root
    ~data_dir ~socket_path () : (module Conf.S) =
  (module struct
    let versioning = versioning
    let client_name = client_name
    let domain_name = "test"
    let domain_prefix = "tsync/test/manifests/"
    let chunk_prefix = "tsync/test/chunks/"
    let versions_prefix = "tsync/test/versions/"
    let journal_prefix = "tsync/test/journal/"
    let cursor_key = "tsync/test/cursor"
    let shares_prefix = "tsync/shares/"

    let store =
      Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some backend_root)

    (* What the daemon declares for diagnosis ([bin/cli.ml build_backends]), so
       [stats] has a store to report on here too. *)
    let members =
      [
        Backend.member ~name:"backend" ~backend_type:"local"
          ~config:[("path", backend_root)]
          ~local_path:backend_root store;
      ]

    let cache_root = cache_root
    let data_dir = data_dir
    let socket_path = socket_path
    let max_uploads = 4
    let max_chunk_buffers = 4
    let max_downloads = 8
    let chunk_size = Some chunk_size
    let cache_chunk_size = Some cache_chunk_size

    let max_cache =
      match Sys.getenv_opt "TSYNC_MAX_CACHE" with
        | Some s -> Conf_parsing.parse_size s
        | None -> None

    let symlink_policy = `Keep
    let read_only = false
  end)

(* Single client: after draining uploads, snapshot the listing IPC responses
   (directory keys, logical size, content-hash etag, normalized mtime). *)
let run_ipc_scenario ?versioning ({ name; steps } : scenario) =
  reset_ids ();
  Printf.printf "=== %s\n" name;
  List.iter (fun s -> Printf.printf "  %s\n" (render_step s)) steps;
  let root = Filename.temp_dir "tsync-ipc" "" in
  let module C =
    (val make_conf ?versioning ~client_name:"Test Client"
           ~backend_root:(Filename.concat root "backend")
           ~cache_root:(Filename.concat root "cache")
           ~data_dir:(Filename.concat root "data")
           ~socket_path:(Filename.concat root "s.sock")
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

(* The daemon's own report, which [tsync status] renders and the http-proxy serves.
   Only its structure is printed: the rest is pids, uptimes, paths and timings. *)
let run_stats_scenario ?versioning ({ name; steps } : scenario) =
  reset_ids ();
  Printf.printf "=== %s\n" name;
  let root = Filename.temp_dir "tsync-stats-ipc" "" in
  let module C =
    (val make_conf ?versioning ~client_name:"Test Client"
           ~backend_root:(Filename.concat root "backend")
           ~cache_root:(Filename.concat root "cache")
           ~data_dir:(Filename.concat root "data")
           ~socket_path:(Filename.concat root "s.sock")
           ())
  in
  Lwt_main.run
    (let client = setup_client (module C) root "" in
     let* () = Lwt_list.iter_s client.do_step steps in
     let* () = client.drain () in
     let* report = client.stats () in
     let mem name j = Yojson.Safe.Util.member name j in
     let json = `Assoc report in
     Printf.printf "  sections: %s\n"
       (String.concat " "
          (List.filter
             (fun k -> mem k json <> `Null)
             ["server"; "process"; "lwt"; "traffic"; "domains"]));
     let domain =
       match mem "domains" json with `List (d :: _) -> d | _ -> `Null
     in
     Printf.printf "  domain %s: cache=%s wal.pending=%s\n"
       (Yojson.Safe.to_string (mem "name" domain))
       (Yojson.Safe.to_string (mem "chunks" (mem "cache" domain)))
       (Yojson.Safe.to_string (mem "pending" (mem "wal" domain)));
     (match mem "backends" domain with
       | `List l ->
           List.iter
             (fun b ->
               Printf.printf
                 "  backend %s (%s): reachable=%s journal.behind=%s\n"
                 (Yojson.Safe.to_string (mem "name" b))
                 (Yojson.Safe.to_string (mem "role" b))
                 (Yojson.Safe.to_string (mem "reachable" b))
                 (Yojson.Safe.to_string (mem "behind" (mem "journal" b))))
             l
       | _ -> print_endline "  no backends reported");
     let mount =
       match mem "frontends" domain with `List (f :: _) -> f | _ -> `Null
     in
     Printf.printf
       "  frontend %s: reachable=%s stagedFiles=%s metaLocked=%s metaWaiting=%s\n"
       (Yojson.Safe.to_string (mem "type" mount))
       (Yojson.Safe.to_string (mem "reachable" mount))
       (Yojson.Safe.to_string (mem "stagedFiles" mount))
       (Yojson.Safe.to_string (mem "metaLocked" mount))
       (Yojson.Safe.to_string (mem "metaWaiting" mount));
     (* The report renders for a person without raising on any of it. *)
     Printf.printf "  renders as text: %b\n"
       (String.length (Diagnostics.text json) > 0);
     client.stop ());
  rm_rf root;
  print_newline ()

(* Two clients on one backend: A applies the steps, then B's change feed is
   probed from several anchors — a baseline (working delta), B's current cursor
   (up to date), and a pruned-past anchor (stale → full re-list). *)
let run_ipc_changes_scenario ?versioning ({ name; steps } : scenario) =
  reset_ids ();
  Printf.printf "=== %s\n" name;
  List.iter (fun s -> Printf.printf "  A: %s\n" (render_step s)) steps;
  let root = Filename.temp_dir "tsync-ipc2" "" in
  let backend_root = Filename.concat root "backend" in
  let module Ca =
    (val make_conf ?versioning ~client_name:"Client A" ~backend_root
           ~cache_root:(Filename.concat root "cache-a")
           ~data_dir:(Filename.concat root "data-a")
           ~socket_path:(Filename.concat root "a.sock")
           ())
  in
  let module Cb =
    (val make_conf ?versioning ~client_name:"Client B" ~backend_root
           ~cache_root:(Filename.concat root "cache-b")
           ~data_dir:(Filename.concat root "data-b")
           ~socket_path:(Filename.concat root "b.sock")
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

let run_stats ?versioning scenarios =
  List.iter (run_stats_scenario ?versioning) scenarios
