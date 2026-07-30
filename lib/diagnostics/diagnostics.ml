(* What a running tsync process can say about itself when something is wrong.

   One collector, two consumers: the http-proxy status endpoints (which have no
   IPC socket to answer on) and the [diagnostics] IPC action behind
   [tsync diagnose]. Both render with {!text}, so a server and a mount report the
   same shape and the same numbers.

   Everything here is either in-process state or a bounded read. The exception is
   [?totals:true], which enumerates the manifest and chunk namespaces: it is
   opt-in precisely because its cost grows with the domain. *)

open Lwt.Syntax

let started_at = Unix.gettimeofday ()

let level_name = function
  | `debug -> "debug"
  | `info -> "info"
  | `warn -> "warn"
  | `err -> "err"

(* Journal keys to sample per backend. A domain's journal is unbounded and this
   is a diagnosis page: report a bound rather than pay for one. *)
let journal_sample = 1000

(* ── Process-wide sections ──────────────────────────────────────────────── *)

(* [extra] is what the caller knows and this module cannot: the http-proxy's
   listening port, its request counters. *)
let process_json ?(extra = []) () =
  let uptime = Unix.gettimeofday () -. started_at in
  let cpu = Metrics.cpu_seconds () in
  let gc = Metrics.gc_stats () in
  let lwt = Metrics.lwt_stats () in
  [
    ( "server",
      `Assoc
        ([
           ("hostname", `String (Unix.gethostname ()));
           ("pid", `Int (Unix.getpid ()));
           ("startedAt", `Float started_at);
           ("uptimeSeconds", `Float uptime);
         ]
        @ extra) );
    ( "process",
      `Assoc
        [
          ("cpuSeconds", `Float cpu);
          ( "cpuPercentAvg",
            `Float (if uptime > 0. then 100. *. cpu /. uptime else 0.) );
          ("rssBytes", `Int (Metrics.rss_bytes ()));
          ("heapBytes", `Int gc.Metrics.heap_bytes);
          ("topHeapBytes", `Int gc.Metrics.top_heap_bytes);
          ("minorCollections", `Int gc.Metrics.minor_collections);
          ("majorCollections", `Int gc.Metrics.major_collections);
        ] );
    ( "lwt",
      `Assoc
        [
          ("readableFds", `Int lwt.Metrics.readable_fds);
          ("writableFds", `Int lwt.Metrics.writable_fds);
          ("timers", `Int lwt.Metrics.timers);
          ("poolSize", `Int lwt.Metrics.pool_size);
        ] );
    ( "traffic",
      `Assoc
        [
          ("bytesUploaded", `Int (Metrics.uploaded ()));
          ("bytesDownloaded", `Int (Metrics.downloaded ()));
          ("uploadBytesPerSec", `Int (int_of_float (Metrics.upload_rate ())));
          ("downloadBytesPerSec", `Int (int_of_float (Metrics.download_rate ())));
          ("chunksHashed", `Int (Metrics.hashed ()));
          ("hashesPerSec", `Int (int_of_float (Metrics.hash_rate ())));
        ] );
    ( "recentErrors",
      `List
        (List.map
           (fun (t, level, msg) ->
             `Assoc
               [
                 ("t", `Float t);
                 ("level", `String (level_name level));
                 ("message", `String msg);
               ])
           (Log.recent ())) );
  ]

(* ── Per-domain ─────────────────────────────────────────────────────────── *)

module Make (C : Conf.S) = struct
  module R = Remote.Make_with_layout (C) (Layout.Identity)
  module D = Data.Make (C) (R)
  module Fs = File_store.Make (C)
  module J = Journal.Make (C)

  let int_opt = function Some n -> `Int n | None -> `Null

  (* Can this store answer at all, and how fast? One key is enough — the point is
     the round trip, not the listing. *)
  let probe (module B : Backend.S) =
    let t0 = Unix.gettimeofday () in
    Lwt.catch
      (fun () ->
        let+ _ = B.list_prefix ~max_keys:1 ~prefix:C.domain_prefix () in
        let ms = 1000. *. (Unix.gettimeofday () -. t0) in
        [("reachable", `Bool true); ("latencyMs", `Float ms); ("error", `Null)])
      (fun exn ->
        Lwt.return
          [
            ("reachable", `Bool false);
            ("latencyMs", `Null);
            ("error", `String (Printexc.to_string exn));
          ])

  (* Entries published in this store against what this client has applied:
     [behind] is what a sync pass would still have to do, our own entries
     excluded — they are ours already. *)
  let journal (module B : Backend.S) =
    Lwt.catch
      (fun () ->
        let* entries =
          B.list_prefix ~max_keys:(journal_sample + 1) ~prefix:C.journal_prefix
            ()
        in
        let+ cursor = B.get_opt ~key:C.cursor_key () in
        let my_uuid = J.client_uuid () in
        let last = Filename.basename (Fs.read_last_sync_key ()) in
        let prefix_len = String.length C.journal_prefix in
        let basenames =
          List.filter_map
            (fun (e : Backend.file_entry) ->
              if String.length e.key > prefix_len then
                Some
                  (String.sub e.key prefix_len
                     (String.length e.key - prefix_len))
              else None)
            entries
        in
        let behind =
          List.filter
            (fun b ->
              (last = "" || b > last)
              &&
                try Journal.client_uuid_of_filename b <> my_uuid
                with _ -> false)
            basenames
        in
        `Assoc
          [
            ("entries", `Int (List.length basenames));
            ("behind", `Int (List.length behind));
            ("truncated", `Bool (List.length basenames > journal_sample));
            ( "cursor",
              match cursor with
                | Some c -> `String (String.trim c)
                | None -> `Null );
            ("lastSync", `String last);
          ])
      (fun exn ->
        Lwt.return (`Assoc [("error", `String (Printexc.to_string exn))]))

  (* What this store actually holds. Enumerates two namespaces in full, which is
     why it is behind [?totals]. *)
  let totals_of (module B : Backend.S) =
    Lwt.catch
      (fun () ->
        let* manifests = B.list_prefix ~prefix:C.domain_prefix () in
        let+ chunks = B.list_prefix ~prefix:C.chunk_prefix () in
        `Assoc
          [
            ("manifests", `Int (List.length manifests));
            ("chunks", `Int (List.length chunks));
            ( "chunkBytes",
              `Int
                (List.fold_left
                   (fun acc (e : Backend.file_entry) -> acc + e.size)
                   0 chunks) );
          ])
      (fun exn ->
        Lwt.return (`Assoc [("error", `String (Printexc.to_string exn))]))

  let member_json ~totals (m : Backend.member) =
    let* probed = probe m.Backend.backend in
    let* jrnl = journal m.Backend.backend in
    let+ tot =
      if totals then
        let+ t = totals_of m.Backend.backend in
        [("totals", t)]
      else Lwt.return []
    in
    let backfill =
      match (m.Backend.pending, m.in_flight, m.degraded) with
        | Some queued, Some in_flight, Some degraded ->
            [
              ( "backfill",
                `Assoc
                  [
                    ("queued", `Int (queued ()));
                    ("inFlight", `Int (in_flight ()));
                    ("degraded", `Bool (degraded ()));
                  ] );
            ]
        | _ -> []
    in
    `Assoc
      ((("name", `String m.Backend.name) :: ("role", `String m.role) :: probed)
      @ [("journal", jrnl)]
      @ backfill @ tot)

  let symlink_policy =
    match C.symlink_policy with
      | `Keep -> "keep"
      | `Follow -> "follow"
      | `Skip -> "skip"

  (* The config as this process resolved it — not as the file spells it. A
     misplaced or misspelled key shows up here as the default it fell back to,
     which is the whole point of reading it from {!Conf.S}. *)
  let config_json =
    [
      ("name", `String C.domain_name);
      ("clientName", `String C.client_name);
      ("versioning", `Bool C.versioning);
      ("symlinks", `String symlink_policy);
      ("domainReadOnly", `Bool C.read_only);
      ("chunkSize", int_opt C.chunk_size);
      ("cacheChunkSize", `Int (Conf.cache_chunk_size (module C)));
      ("maxCache", int_opt C.max_cache);
      ("maxUploads", `Int C.max_uploads);
      ("maxDownloads", `Int C.max_downloads);
      ("cacheRoot", `String C.cache_root);
      ("dataDir", `String C.data_dir);
      ("socketPath", `String C.socket_path);
      ("domainPrefix", `String C.domain_prefix);
      ("chunkPrefix", `String C.chunk_prefix);
    ]

  (* Files in the local manifest mirror, markers excluded. A full tree walk, so
     it is only done under [?totals]. *)
  let rec count_mirror dir =
    let* names =
      Lwt.catch (fun () -> Fs_util.readdir_list dir) (fun _ -> Lwt.return_nil)
    in
    Lwt_list.fold_left_s
      (fun acc name ->
        let path = Filename.concat dir name in
        let* is_dir = Fs_util.is_directory path in
        if is_dir then
          let+ n = count_mirror path in
          acc + n
        else
          Lwt.return
            (if String.starts_with ~prefix:".tsync" name then acc else acc + 1))
      0 names

  let cache_json ~totals =
    let* chunks, bytes = D.chunk_stats () in
    let+ manifests =
      if totals then
        let+ n =
          count_mirror
            (Cache_layout.manifests_dir ~cache_root:C.cache_root C.domain_name)
        in
        [("manifests", `Int n)]
      else Lwt.return []
    in
    `Assoc
      ([
         ("chunks", `Int chunks);
         ("bytes", `Int bytes);
         ("maxCache", int_opt C.max_cache);
       ]
      @ manifests)

  let local_pending () =
    Lwt.catch
      (fun () ->
        let+ entries = J.local_pending_entries ~uuid:(J.client_uuid ()) in
        List.length entries)
      (fun _ -> Lwt.return 0)

  (* [extra] carries what only the calling frontend knows — the http-proxy adds
     its serve-side readOnly, whether it serves shares, and its options. [mount]
     is the mount daemon's own queues: supplied directly when this *is* that
     daemon, and fetched over IPC when a proxy is reporting on one. *)
  let domain_json ?(totals = false) ?(extra = []) ?mount () =
    let* cache = cache_json ~totals in
    let* pending = local_pending () in
    let+ backends =
      Lwt_list.map_p (member_json ~totals)
        (Backend.members ~domain:C.domain_name)
    in
    `Assoc
      (config_json @ extra
      @ [
          ("cache", cache);
          ("journal", `Assoc [("localPending", `Int pending)]);
          ("backends", `List backends);
        ]
      @ match mount with Some m -> [("mount", m)] | None -> [])
end

(* ── Text rendering ─────────────────────────────────────────────────────── *)

(* One renderer for every consumer, so a browser, [curl] and [tsync diagnose]
   cannot disagree about what the process just said. Reads the JSON rather than
   the records for the same reason. *)

let mem j name = try Yojson.Safe.Util.member name j with _ -> `Null
let str ?(default = "") j = match j with `String s -> s | _ -> default
let num j = match j with `Int n -> float_of_int n | `Float f -> f | _ -> 0.
let int_of j = int_of_float (num j)
let bool_of j = match j with `Bool b -> b | _ -> false

let bytes_or_unlimited j =
  match j with `Null -> "unlimited" | j -> Metrics.human_bytes (int_of j)

(* An unset chunk size is not an absent limit: the effective value is whatever the
   primary backend recommends, and the built-in default when it has no opinion. *)
let bytes_or_default j =
  match j with
    | `Null ->
        Printf.sprintf "not set (%s default)"
          (Metrics.human_bytes Conf.default_chunk_size)
    | j -> Metrics.human_bytes (int_of j)

let duration s =
  let s = int_of_float s in
  let d = s / 86400 and h = s mod 86400 / 3600 in
  let m = s mod 3600 / 60 in
  if d > 0 then Printf.sprintf "%dd %dh" d h
  else if h > 0 then Printf.sprintf "%dh %dm" h m
  else Printf.sprintf "%dm %ds" m (s mod 60)

let text json =
  let b = Buffer.create 4096 in
  let line indent fmt =
    Printf.ksprintf
      (fun s -> Buffer.add_string b (String.make indent ' ' ^ s ^ "\n"))
      fmt
  in
  let row indent label value = line indent "%-16s %s" label value in
  let server = mem json "server" in
  let proc = mem json "process" in
  let lwt = mem json "lwt" in
  let traffic = mem json "traffic" in
  line 0 "tsync %s (pid %d), up %s"
    (str ~default:"?" (mem server "hostname"))
    (int_of (mem server "pid"))
    (duration (num (mem server "uptimeSeconds")));
  (match mem server "port" with
    | `Null -> ()
    | p ->
        row 2 "listener"
          (Printf.sprintf "port %d, %s" (int_of p)
             (if bool_of (mem server "tls") then "https" else "http")));
  row 2 "cpu"
    (Printf.sprintf "%.1fs (%.1f%% avg)"
       (num (mem proc "cpuSeconds"))
       (num (mem proc "cpuPercentAvg")));
  row 2 "memory"
    (Printf.sprintf "%s rss, %s heap (peak %s)"
       (Metrics.human_bytes (int_of (mem proc "rssBytes")))
       (Metrics.human_bytes (int_of (mem proc "heapBytes")))
       (Metrics.human_bytes (int_of (mem proc "topHeapBytes"))));
  row 2 "gc"
    (Printf.sprintf "%d minor, %d major"
       (int_of (mem proc "minorCollections"))
       (int_of (mem proc "majorCollections")));
  row 2 "event loop"
    (Printf.sprintf "%d readable, %d writable, %d timers, pool %d"
       (int_of (mem lwt "readableFds"))
       (int_of (mem lwt "writableFds"))
       (int_of (mem lwt "timers"))
       (int_of (mem lwt "poolSize")));
  line 0 "";
  line 0 "Traffic";
  row 2 "uploaded"
    (Printf.sprintf "%s (%s/s)"
       (Metrics.human_bytes (int_of (mem traffic "bytesUploaded")))
       (Metrics.human_bytes (int_of (mem traffic "uploadBytesPerSec"))));
  row 2 "downloaded"
    (Printf.sprintf "%s (%s/s)"
       (Metrics.human_bytes (int_of (mem traffic "bytesDownloaded")))
       (Metrics.human_bytes (int_of (mem traffic "downloadBytesPerSec"))));
  row 2 "hashed"
    (Printf.sprintf "%d chunks (%d/s)"
       (int_of (mem traffic "chunksHashed"))
       (int_of (mem traffic "hashesPerSec")));
  (match mem json "requests" with
    | `Assoc fields ->
        line 0 "";
        line 0 "Requests";
        List.iter (fun (k, v) -> row 2 k (string_of_int (int_of v))) fields
    | _ -> ());
  let domains = match mem json "domains" with `List l -> l | _ -> [] in
  List.iter
    (fun d ->
      line 0 "";
      line 0 "Domain %s" (str (mem d "name"));
      row 2 "client name" (str (mem d "clientName"));
      row 2 "read-only"
        (if bool_of (mem d "readOnly") then "yes (proxy clients)"
         else if bool_of (mem d "domainReadOnly") then "yes"
         else "no");
      row 2 "versioning" (if bool_of (mem d "versioning") then "on" else "off");
      row 2 "symlinks" (str (mem d "symlinks"));
      row 2 "chunk size" (bytes_or_default (mem d "chunkSize"));
      row 2 "cache chunk" (bytes_or_unlimited (mem d "cacheChunkSize"));
      row 2 "concurrency"
        (Printf.sprintf "%d uploads, %d downloads"
           (int_of (mem d "maxUploads"))
           (int_of (mem d "maxDownloads")));
      row 2 "cache root" (str (mem d "cacheRoot"));
      row 2 "socket" (str (mem d "socketPath"));
      (match mem d "options" with
        | `Assoc opts ->
            List.iter (fun (k, v) -> row 2 ("option " ^ k) (str v)) opts
        | _ -> ());
      let cache = mem d "cache" in
      line 2 "Cache";
      row 4 "chunks"
        (Printf.sprintf "%d (%s of %s)"
           (int_of (mem cache "chunks"))
           (Metrics.human_bytes (int_of (mem cache "bytes")))
           (bytes_or_unlimited (mem cache "maxCache")));
      (match mem cache "manifests" with
        | `Null -> ()
        | m -> row 4 "manifests" (string_of_int (int_of m)));
      row 4 "unpublished"
        (Printf.sprintf "%d journal entries"
           (int_of (mem (mem d "journal") "localPending")));
      List.iter
        (fun m ->
          line 2 "Backend %s (%s)" (str (mem m "name")) (str (mem m "role"));
          if bool_of (mem m "reachable") then
            row 4 "reachable"
              (Printf.sprintf "yes (%.0f ms)" (num (mem m "latencyMs")))
          else row 4 "UNREACHABLE" (str ~default:"no answer" (mem m "error"));
          let j = mem m "journal" in
          (match mem j "error" with
            | `String e -> row 4 "journal" ("error: " ^ e)
            | _ ->
                row 4 "journal"
                  (Printf.sprintf "%d entries%s, %d to apply"
                     (int_of (mem j "entries"))
                     (if bool_of (mem j "truncated") then "+" else "")
                     (int_of (mem j "behind"))));
          (match mem m "backfill" with
            | `Null -> ()
            | bf ->
                row 4 "backfill"
                  (Printf.sprintf "%d queued, %d in flight%s"
                     (int_of (mem bf "queued"))
                     (int_of (mem bf "inFlight"))
                     (if bool_of (mem bf "degraded") then
                        " — DEGRADED, run tsync resync-remote"
                      else "")));
          match mem m "totals" with
            | `Null -> ()
            | t -> (
                (* "Could not look" must never read as "holds nothing". *)
                  match mem t "error" with
                  | `String e -> row 4 "holds" ("could not count: " ^ e)
                  | _ ->
                      row 4 "holds"
                        (Printf.sprintf "%d manifests, %d chunks, %s"
                           (int_of (mem t "manifests"))
                           (int_of (mem t "chunks"))
                           (Metrics.human_bytes (int_of (mem t "chunkBytes"))))))
        (match mem d "backends" with `List l -> l | _ -> []);
      match mem d "mount" with
        | `Null -> ()
        | m ->
            line 2 "Mount daemon";
            if bool_of (mem m "reachable") then
              List.iter
                (fun (k, v) ->
                  if k <> "reachable" then
                    row 4 k
                      (match v with
                        | `String s -> s
                        | `Int n -> string_of_int n
                        | v -> Yojson.Safe.to_string v))
                (match m with `Assoc f -> f | _ -> [])
            else row 4 "unreachable" (str ~default:"no answer" (mem m "error")))
    domains;
  (match mem json "recentErrors" with
    | `List [] | `Null -> ()
    | `List errs ->
        line 0 "";
        line 0 "Recent warnings and errors (newest first)";
        List.iter
          (fun e ->
            let t = Unix.localtime (num (mem e "t")) in
            line 2 "%02d:%02d:%02d %-5s %s" t.Unix.tm_hour t.Unix.tm_min
              t.Unix.tm_sec
              (str (mem e "level"))
              (str (mem e "message")))
          errs
    | _ -> ());
  Buffer.contents b
