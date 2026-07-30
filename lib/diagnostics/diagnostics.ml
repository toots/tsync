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

  (* Can this store answer, and how fast? Fetching the cursor — one small object at
     a known key — is the whole probe: an answer of any kind means the store is
     reachable, and a miss is still an answer. Deliberately not a listing: a
     [local] backend walks its whole tree before honouring [max_keys], so "list one
     key" costs a stat per manifest in the domain. The body comes back too, because
     the journal section wants exactly this object. *)
  let probe (module B : Backend.S) =
    let t0 = Unix.gettimeofday () in
    Lwt.catch
      (fun () ->
        let+ cursor = B.get_opt ~key:C.cursor_key () in
        let ms = 1000. *. (Unix.gettimeofday () -. t0) in
        ( [("reachable", `Bool true); ("latencyMs", `Float ms); ("error", `Null)],
          cursor ))
      (fun exn ->
        Lwt.return
          ( [
              ("reachable", `Bool false);
              ("latencyMs", `Null);
              ("error", `String (Printexc.to_string exn));
            ],
            None ))

  (* Entries published in this store against what this client has applied:
     [behind] is what a sync pass would still have to do, our own entries
     excluded — they are ours already. *)
  let journal ~cursor (module B : Backend.S) =
    Lwt.catch
      (fun () ->
        let+ entries =
          B.list_prefix ~max_keys:(journal_sample + 1) ~prefix:C.journal_prefix
            ()
        in
        let my_uuid = J.client_uuid () in
        (* [basename ""] is ".", which would both read as nonsense and make the
           "never synced" case below compare against it instead of matching. *)
        let last =
          match Fs.read_last_sync_key () with
            | "" -> ""
            | key -> Filename.basename key
        in
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

  (* What this store actually holds: manifests, chunks, bytes. There is no cheap
     way to know — it means enumerating two namespaces, which is a stat per file on
     a [local] store and a paged LIST on a bucket, and grows with the domain.

     So it is never counted while a request waits. A request serves the last
     sample and says how old it is, kicking off a refresh in the background when
     that sample has gone stale; the first ever request answers "counting". A
     figure a few minutes old is worth having, and a status endpoint that blocks
     for a 100k-object walk is not. *)
  let totals_max_age = 300.

  type sample = { at : float; counts : Yojson.Safe.t }

  let samples : (string, sample) Hashtbl.t = Hashtbl.create 4
  let counting : (string, unit) Hashtbl.t = Hashtbl.create 4

  let count_now ~name (module B : Backend.S) =
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
        Log.warn "diagnostics: counting %s: %s" name (Printexc.to_string exn);
        Lwt.return (`Assoc [("error", `String (Printexc.to_string exn))]))

  (* One walk at a time per store: a page refreshing every few seconds must not
     stack walks on top of each other. *)
  let refresh ~name backend =
    if not (Hashtbl.mem counting name) then begin
      Hashtbl.replace counting name ();
      Lwt.async (fun () ->
          Lwt.finalize
            (fun () ->
              let+ counts = count_now ~name backend in
              Hashtbl.replace samples name { at = Unix.gettimeofday (); counts })
            (fun () ->
              Hashtbl.remove counting name;
              Lwt.return_unit))
    end

  let totals_of ~name backend =
    let now = Unix.gettimeofday () in
    match Hashtbl.find_opt samples name with
      | Some s ->
          if now -. s.at > totals_max_age then refresh ~name backend;
          let with_age =
            match s.counts with
              | `Assoc fields ->
                  `Assoc
                    (fields
                    @ [("sampledSecondsAgo", `Int (int_of_float (now -. s.at)))]
                    )
              | other -> other
          in
          with_age
      | None ->
          refresh ~name backend;
          `Assoc [("counting", `Bool true)]

  (* Room left where a local store keeps its files. One syscall, so unlike the
     counts above this is always reported. *)
  let disk_json (m : Backend.member) =
    match Option.bind m.Backend.local_path Fs_util.disk_space with
      | None -> []
      | Some (available, total) ->
          [
            ( "disk",
              `Assoc
                [
                  ("availableBytes", `Int (Int64.to_int available));
                  ("totalBytes", `Int (Int64.to_int total));
                ] );
          ]

  let member_json ~totals (m : Backend.member) =
    let* probed, cursor = probe m.Backend.backend in
    let+ jrnl = journal ~cursor m.Backend.backend in
    (* Synchronous: it reads the last sample and, if that is stale, leaves a walk
       running behind us rather than waiting for one. *)
    let tot =
      if totals then
        [("totals", totals_of ~name:m.Backend.name m.Backend.backend)]
      else []
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
      @ disk_json m @ backfill @ tot)

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
          (* Room left where a local store keeps its files: one syscall, so this is
             here on every request, unlike the counts below. *)
          (match mem m "disk" with
            | `Null -> ()
            | d ->
                let avail = int_of (mem d "availableBytes")
                and total = int_of (mem d "totalBytes") in
                row 4 "disk"
                  (Printf.sprintf "%s free of %s (%d%% used)"
                     (Metrics.human_bytes avail)
                     (Metrics.human_bytes total)
                     (if total > 0 then 100 * (total - avail) / total else 0)));
          match mem m "totals" with
            | `Null -> ()
            | t -> (
                (* "Could not look" must never read as "holds nothing", and neither
                   must "not counted yet" — that walk runs in the background. *)
                  match (mem t "error", mem t "counting") with
                  | `String e, _ -> row 4 "holds" ("could not count: " ^ e)
                  | _, `Bool true -> row 4 "holds" "counting in the background"
                  | _ ->
                      row 4 "holds"
                        (Printf.sprintf "%d manifests, %d chunks, %s%s"
                           (int_of (mem t "manifests"))
                           (int_of (mem t "chunks"))
                           (Metrics.human_bytes (int_of (mem t "chunkBytes")))
                           (match mem t "sampledSecondsAgo" with
                             | `Null -> ""
                             | age ->
                                 Printf.sprintf ", as of %s ago"
                                   (duration (num age))))))
        (match mem d "backends" with `List l -> l | _ -> []);
      match mem d "mount" with
        | `Null -> ()
        | m ->
            (* A separate process with its own counters, so its figures are shown
               under its own heading rather than folded into ours. *)
            line 2 "Mount daemon%s"
              (match mem m "frontend" with
                | `String f -> Printf.sprintf " (%s)" f
                | _ -> "");
            if not (bool_of (mem m "reachable")) then
              row 4 "unreachable" (str ~default:"no answer" (mem m "error"))
            else begin
              (match mem m "pid" with
                | `Null -> ()
                | pid ->
                    row 4 "process"
                      (Printf.sprintf "pid %d, up %s, %.1fs cpu, %s rss"
                         (int_of pid)
                         (duration (num (mem m "uptimeSeconds")))
                         (num (mem m "cpuSeconds"))
                         (Metrics.human_bytes (int_of (mem m "rssBytes")))));
              (match mem m "traffic" with
                | `Null -> ()
                | t ->
                    row 4 "uploaded"
                      (Printf.sprintf "%s (%s/s)"
                         (Metrics.human_bytes (int_of (mem t "bytesUploaded")))
                         (Metrics.human_bytes
                            (int_of (mem t "uploadBytesPerSec"))));
                    row 4 "downloaded"
                      (Printf.sprintf "%s (%s/s)"
                         (Metrics.human_bytes
                            (int_of (mem t "bytesDownloaded")))
                         (Metrics.human_bytes
                            (int_of (mem t "downloadBytesPerSec"))));
                    row 4 "hashed"
                      (Printf.sprintf "%d chunks (%d/s)"
                         (int_of (mem t "chunksHashed"))
                         (int_of (mem t "hashesPerSec"))));
              (* Volume through the frontend itself — what fuse serves out of the
                 chunk cache never touches a backend, so this is the only place it
                 shows up. Paired with its rate: whether the mount is busy *now* is
                 what a total cannot say. *)
              List.iter
                (fun (label, total_key, rate_key) ->
                  match mem m total_key with
                    | `Null -> ()
                    | v ->
                        row 4 label
                          (Printf.sprintf "%s (%s/s)"
                             (Metrics.human_bytes (int_of v))
                             (Metrics.human_bytes (int_of (mem m rate_key)))))
                [
                  ("read", "bytesRead", "bytesReadPerSec");
                  ("written", "bytesWritten", "bytesWrittenPerSec");
                ];
              (match mem m "openHandles" with
                | `Null -> ()
                | v ->
                    row 4 "handles"
                      (Printf.sprintf "%d open, %d since start" (int_of v)
                         (int_of (mem m "filesOpened"))));
              (* Whatever else the frontend reported — queue depths, staged files,
                 anything a future frontend adds — without this having to know it.
                 A count of bytes is spelled as bytes wherever the name says so, so
                 a new field does not arrive here as a bare integer. *)
              List.iter
                (fun (k, v) ->
                  let is_bytes =
                    (* "bytesRead", "rssBytes", "stagedBytes"… *)
                    let has sub =
                      let n = String.length sub and len = String.length k in
                      let rec at i =
                        i + n <= len && (String.sub k i n = sub || at (i + 1))
                      in
                      at 0
                    in
                    has "bytes" || has "Bytes"
                  in
                  match (k, v) with
                    | ( ( "reachable" | "frontend" | "pid" | "uptimeSeconds"
                        | "cpuSeconds" | "rssBytes" | "traffic" | "bytesRead"
                        | "bytesWritten" | "bytesReadPerSec"
                        | "bytesWrittenPerSec" | "openHandles" | "filesOpened"
                          ),
                        _ ) ->
                        ()
                    | _, `String s -> row 4 k s
                    | _, `Int n when is_bytes -> row 4 k (Metrics.human_bytes n)
                    | _, `Int n -> row 4 k (string_of_int n)
                    | _, `Bool b -> row 4 k (string_of_bool b)
                    | _, v -> row 4 k (Yojson.Safe.to_string v))
                (match m with `Assoc f -> f | _ -> [])
            end)
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
