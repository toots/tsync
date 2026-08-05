(* What a running tsync process can say about itself when something is wrong.

   One collector, two consumers: the http-proxy status endpoints (which have no
   IPC socket) and the [diagnostics] IPC action behind [tsync diagnose]. Both
   render with {!text}, so a server and a mount report the same shape.

   Everything here is in-process state or a bounded read, except [?totals:true],
   which reaches into the store and is opt-in for that reason. Even then the
   chunk count is sampled unless [?exact:true]. *)

open Lwt.Syntax

let started_at = Unix.gettimeofday ()

let level_name = function
  | `debug -> "debug"
  | `info -> "info"
  | `warn -> "warn"
  | `err -> "err"

(* A domain's journal is unbounded and this is a diagnosis page. *)
let journal_sample = 1000

(* The frontend answering this request, as a process.

   At the top rather than under a domain, since a frontend need not belong to
   one: an http-proxy listener's cpu, bytes and request counts cover every domain
   it serves at once, listed in [serves]. A fuse mount is per-domain and appears
   again in that domain's [frontends].

   [extra] is what only the caller knows: the frontend's type, its port, its
   request counters. *)
let self_json ?(extra = []) () =
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

module Make (C : Conf.S) = struct
  module R = Remote.Make_with_layout (C) (Layout.Identity)
  module D = Data.Make (C) (R)
  module Fs = File_store.Make (C)
  module J = Journal.Make (C)

  let int_opt = function Some n -> `Int n | None -> `Null

  (* Fetching the cursor — one small object at a known key — is the whole probe:
     any answer, including a miss, means the store is reachable. Deliberately not
     a listing: a [local] backend walks its whole tree before honouring
     [max_keys]. The body comes back too, since the journal section wants it. *)
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

  (* [behind] is what a sync pass would still have to do, our own entries
     excluded. *)
  let journal ~cursor (module B : Backend.S) =
    Lwt.catch
      (fun () ->
        let+ entries =
          B.list_prefix ~max_keys:(journal_sample + 1) ~prefix:C.journal_prefix
            ()
        in
        let my_uuid = J.client_uuid () in
        (* [basename ""] is ".", which reads as nonsense and stops the "never
           synced" case below from matching. *)
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

  (* Manifests, chunks and bytes held by the store. Reading either namespace
     whole is a stat per file on [local] and a paged LIST on a bucket, growing
     with the domain, so the chunk figure is sampled (see [count_chunks]) unless
     [~exact].

     Never counted while a request waits: a request serves the last sample with
     its age, and the first one answers "counting" while a walk starts behind it.
     A sample stands until [~reload], so walking a store is always something
     someone chose. *)
  type sample = { at : float; counts : Yojson.Safe.t }

  let samples : (string, sample) Hashtbl.t = Hashtbl.create 4
  let counting : (string, unit) Hashtbl.t = Hashtbl.create 4

  (* Keys are uniformly hashed, so a shard's share of the store is its share of
     the shard space: count a few and scale. With 16 of 4096 shards, a million
     chunks means ~4000 counted and a relative error near 1.5%. *)
  let sampled_shards = 16

  (* Filesystem backends list an empty directory as its own marker key (matching
     S3's zero-byte object). An emptied shard is not a chunk. *)
  let chunk_entries entries =
    List.filter
      (fun (e : Backend.file_entry) ->
        let k = e.Backend.key in
        String.length k > 0 && k.[String.length k - 1] <> '/')
      entries

  let total_bytes =
    List.fold_left (fun acc (e : Backend.file_entry) -> acc + e.Backend.size) 0

  let count_chunks ~exact (module B : Backend.S) =
    if exact then
      let+ chunks = B.list_prefix ~prefix:C.chunk_prefix () in
      let chunks = chunk_entries chunks in
      [
        ("chunks", `Int (List.length chunks));
        ("chunkBytes", `Int (total_bytes chunks));
      ]
    else (
      let step = Chunk_layout.shards / sampled_shards in
      let+ sampled =
        Lwt_list.map_p
          (fun i ->
            let prefix =
              C.chunk_prefix ^ Chunk_layout.shard_name (i * step) ^ "/"
            in
            let+ entries = B.list_prefix ~prefix () in
            chunk_entries entries)
          (List.init sampled_shards Fun.id)
      in
      let sampled = List.concat sampled in
      [
        ("chunks", `Int (List.length sampled * step));
        ("chunkBytes", `Int (total_bytes sampled * step));
        ("chunksFromShards", `Int sampled_shards);
      ])

  let count_now ~name ~exact (module B : Backend.S) =
    Lwt.catch
      (fun () ->
        let* manifests = B.list_prefix ~prefix:C.domain_prefix () in
        (* Manifests are keyed by folder id, not hashed, so nothing is evenly
           spread to sample: this count stays a full walk. It is also the smaller
           of the two, one object per file. *)
        let+ chunks = count_chunks ~exact (module B) in
        `Assoc (("manifests", `Int (List.length manifests)) :: chunks))
      (fun exn ->
        Log.warn "diagnostics: counting %s: %s" name (Printexc.to_string exn);
        Lwt.return (`Assoc [("error", `String (Printexc.to_string exn))]))

  (* One walk at a time per store, or a page refreshing every few seconds stacks
     them. *)
  (* Separate samples: one precision must not be served in place of the other. *)
  let slot ~name ~exact = if exact then name ^ " (exact)" else name

  let refresh ~name ~exact backend =
    let slot = slot ~name ~exact in
    if not (Hashtbl.mem counting slot) then begin
      Hashtbl.replace counting slot ();
      Lwt.async (fun () ->
          Lwt.finalize
            (fun () ->
              let+ counts = count_now ~name ~exact backend in
              Hashtbl.replace samples slot { at = Unix.gettimeofday (); counts })
            (fun () ->
              Hashtbl.remove counting slot;
              Lwt.return_unit))
    end

  (* An already-counted figure is reported by every request: it is in memory, so
     withholding it would cost a walk to learn what is known. [compute] is what
     asking buys — a walk when there is nothing yet, or a fresh one under
     [reload]. *)
  let totals_of ~name ~exact ~compute ~reload backend =
    let now = Unix.gettimeofday () in
    let wanted = slot ~name ~exact in
    if compute && (reload || not (Hashtbl.mem samples wanted)) then
      refresh ~name ~exact backend;
    let served =
      match Hashtbl.find_opt samples wanted with
        | Some s -> Some (wanted, s)
        (* Nothing at the precision asked for; the "~" says which kind this
           is. *)
        | None ->
            let other = slot ~name ~exact:(not exact) in
            Option.map (fun s -> (other, s)) (Hashtbl.find_opt samples other)
    in
    match served with
      (* A walk in flight keeps serving the figure it will replace, so a report
         never blanks out. [refreshing] says a newer one is coming. *)
      | Some (slot, s) -> (
          let extra =
            [("sampledSecondsAgo", `Int (int_of_float (now -. s.at)))]
            @
            if Hashtbl.mem counting slot then [("refreshing", `Bool true)]
            else []
          in
          match s.counts with
            | `Assoc fields -> `Assoc (fields @ extra)
            | other -> other)
      | None when compute -> `Assoc [("counting", `Bool true)]
      | None -> `Null

  (* One syscall, so unlike the counts above this is always reported. *)
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

  let member_json ~totals ~exact ~reload (m : Backend.member) =
    let* probed, cursor = probe m.Backend.backend in
    let+ jrnl = journal ~cursor m.Backend.backend in
    (* Synchronous: reads the last sample and leaves any walk it started running
       behind us. *)
    let tot =
      match
        totals_of ~name:m.Backend.name ~exact ~compute:totals ~reload
          m.Backend.backend
      with
        | `Null -> []
        | counts -> [("totals", counts)]
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
      (("name", `String m.Backend.name)
       :: ("type", `String m.backend_type)
       :: ("role", `String m.role)
       :: ( "config",
            `Assoc (List.map (fun (k, v) -> (k, `String v)) m.Backend.config) )
       :: probed
      @ [("journal", jrnl)]
      @ disk_json m @ backfill @ tot)

  let symlink_policy =
    match C.symlink_policy with
      | `Keep -> "keep"
      | `Follow -> "follow"
      | `Skip -> "skip"

  (* As this process resolved it, not as the file spells it: a misplaced key
     shows up as the default it fell back to. *)
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
      ("maxChunkBuffers", `Int C.max_chunk_buffers);
      ("maxDownloads", `Int C.max_downloads);
      ("cacheRoot", `String C.cache_root);
      ("dataDir", `String C.data_dir);
      ("socketPath", `String C.socket_path);
      ("domainPrefix", `String C.domain_prefix);
      ("chunkPrefix", `String C.chunk_prefix);
    ]

  (* Markers excluded. A full tree walk, so only under [?totals]. *)
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

  (* [extra] is what only the calling frontend knows: the http-proxy adds its
     serve-side readOnly, whether it serves shares, and its options. [mount] is
     the mount daemon's queues — supplied directly when this is that daemon,
     fetched over IPC when a proxy reports on one. *)
  (* Each frontend serving this domain reports what only it knows. A per-domain
     frontend (a fuse mount) is its own process and carries its own cpu and
     transfer figures; a shared listener (the http-proxy) contributes only its
     per-domain settings here, reporting itself once at the top. *)
  let domain_json ?(totals = false) ?(exact = false) ?(reload = false)
      ?(extra = []) ?(frontends = []) () =
    let* cache = cache_json ~totals in
    let* pending = local_pending () in
    let+ backends =
      Lwt_list.map_p
        (member_json ~totals ~exact ~reload)
        (Backend.members ~domain:C.domain_name)
    in
    `Assoc
      (config_json @ extra
      @ [
          ("cache", cache);
          ("journal", `Assoc [("localPending", `Int pending)]);
          ("frontends", `List frontends);
          ("backends", `List backends);
        ])
end

(* One renderer for every consumer, reading the JSON rather than the records, so
   a browser, [curl] and [tsync diagnose] cannot disagree. *)

let mem j name = try Yojson.Safe.Util.member name j with _ -> `Null
let str ?(default = "") j = match j with `String s -> s | _ -> default
let num j = match j with `Int n -> float_of_int n | `Float f -> f | _ -> 0.
let int_of j = int_of_float (num j)
let bool_of j = match j with `Bool b -> b | _ -> false

let bytes_or_unlimited j =
  match j with `Null -> "unlimited" | j -> Metrics.human_bytes (int_of j)

(* Unset is not absent: the effective value is what the primary backend
   recommends, else the built-in default. *)
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
  (* Everything under this heading belongs to the answering process; a shared
     listener lists what it serves, so no figure reads as one domain's. *)
  line 0 "Frontend %s on %s (this process)"
    (str ~default:"?" (mem server "frontend"))
    (str ~default:"?" (mem server "hostname"));
  (match mem server "port" with
    | `Null -> ()
    | p ->
        row 2 "listener"
          (Printf.sprintf "port %d, %s" (int_of p)
             (if bool_of (mem server "tls") then "https" else "http")));
  (match mem server "serves" with
    | `List domains when domains <> [] ->
        row 2 "serving"
          (Printf.sprintf "%d domain%s: %s" (List.length domains)
             (if List.length domains = 1 then "" else "s")
             (String.concat ", " (List.map str domains)))
    | _ -> ());
  row 2 "process"
    (Printf.sprintf "pid %d, up %s"
       (int_of (mem server "pid"))
       (duration (num (mem server "uptimeSeconds"))));
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
  row 2 "traffic"
    (Printf.sprintf "up %s (%s/s), down %s (%s/s)"
       (Metrics.human_bytes (int_of (mem traffic "bytesUploaded")))
       (Metrics.human_bytes (int_of (mem traffic "uploadBytesPerSec")))
       (Metrics.human_bytes (int_of (mem traffic "bytesDownloaded")))
       (Metrics.human_bytes (int_of (mem traffic "downloadBytesPerSec"))));
  row 2 "hashed"
    (Printf.sprintf "%d chunks (%d/s)"
       (int_of (mem traffic "chunksHashed"))
       (int_of (mem traffic "hashesPerSec")));
  (match mem server "requests" with
    | `Assoc fields ->
        (* Counters and gauges are kept apart: a gauge of zero is an idle
           server, a counter of zero one never asked, and "0 dataWaiting" beside
           "2 stats" invites reading the first as the second. *)
        let is_gauge k =
          List.mem k ["inFlight"; "dataInFlight"; "dataWaiting"]
        in
        let gauges, served = List.partition (fun (k, _) -> is_gauge k) fields in
        let gauge k =
          match List.assoc_opt k gauges with Some v -> int_of v | None -> 0
        in
        (* Non-zero only: an empty queue is the normal case and printing it
           every time buries the one that matters. *)
        let live =
          List.filter_map
            (fun (label, key) ->
              let n = gauge key in
              if n > 0 then Some (Printf.sprintf "%d %s" n label) else None)
            [("in flight", "inFlight"); ("waiting on storage", "dataWaiting")]
        in
        row 2 "requests"
          (Printf.sprintf "%s%s"
             (if served = [] then "none served"
              else
                String.concat ", "
                  (List.map
                     (fun (k, v) -> Printf.sprintf "%d %s" (int_of v) k)
                     served))
             (if live = [] then "" else " (" ^ String.concat ", " live ^ ")"))
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
      (* Chunk buffers belong here and not only in the frontend block: they are
         what bounds the upload path's memory, so reading it against the chunk
         size above is how an operator sizes a small machine. *)
      row 2 "concurrency"
        (Printf.sprintf "%d uploads, %d chunk buffers, %d downloads"
           (int_of (mem d "maxUploads"))
           (int_of (mem d "maxChunkBuffers"))
           (int_of (mem d "maxDownloads")));
      row 2 "cache root" (str (mem d "cacheRoot"));
      row 2 "socket" (str (mem d "socketPath"));
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
      (* A shared listener contributes its per-domain settings here and points at
         the block above for figures it cannot attribute to one domain. *)
      List.iter
        (fun f ->
          (* A frontend that never answered cannot say what it is. *)
          line 2 "Frontend %s%s"
            (str
               ~default:
                 (if bool_of (mem f "reachable") then "(unknown)"
                  else "(none answering)")
               (mem f "type"))
            (if bool_of (mem f "shared") then " (shared listener, see above)"
             else "");
          if not (bool_of (mem f "reachable")) then
            row 4 "NOT ANSWERING"
              (Printf.sprintf "%s%s"
                 (match mem f "socketPath" with
                   | `String p -> p ^ ": "
                   | _ -> "")
                 (str ~default:"no answer" (mem f "error")))
          else begin
            (match mem f "pid" with
              | `Null -> ()
              | pid ->
                  row 4 "process"
                    (Printf.sprintf "pid %d, up %s, %.1fs cpu, %s rss"
                       (int_of pid)
                       (duration (num (mem f "uptimeSeconds")))
                       (num (mem f "cpuSeconds"))
                       (Metrics.human_bytes (int_of (mem f "rssBytes")))));
            (match mem f "traffic" with
              | `Null -> ()
              | t ->
                  row 4 "traffic"
                    (Printf.sprintf "up %s (%s/s), down %s (%s/s)"
                       (Metrics.human_bytes (int_of (mem t "bytesUploaded")))
                       (Metrics.human_bytes
                          (int_of (mem t "uploadBytesPerSec")))
                       (Metrics.human_bytes (int_of (mem t "bytesDownloaded")))
                       (Metrics.human_bytes
                          (int_of (mem t "downloadBytesPerSec")))));
            List.iter
              (fun (label, total_key, rate_key) ->
                match mem f total_key with
                  | `Null -> ()
                  | v ->
                      row 4 label
                        (Printf.sprintf "%s (%s/s)"
                           (Metrics.human_bytes (int_of v))
                           (Metrics.human_bytes (int_of (mem f rate_key)))))
              [
                ("read", "bytesRead", "bytesReadPerSec");
                ("written", "bytesWritten", "bytesWrittenPerSec");
              ];
            (match mem f "openHandles" with
              | `Null -> ()
              | v ->
                  row 4 "handles"
                    (Printf.sprintf "%d open, %d since start" (int_of v)
                       (int_of (mem f "filesOpened"))));
            (match mem f "metaLocked" with
              | `Null -> ()
              | locked ->
                  row 4 "metadata lock"
                    (if bool_of locked then
                       if bool_of (mem f "metaWaiting") then
                         "HELD, callers waiting"
                       else "held"
                     else "free"));
            (* This listener's stance on the domain, not the domain's own. *)
            (match mem f "readOnly" with
              | `Bool true -> row 4 "read-only" "yes, for proxy clients"
              | _ -> ());
            (match mem f "shares" with
              | `Bool b -> row 4 "public shares" (if b then "served" else "off")
              | _ -> ());
            (match mem f "options" with
              | `Assoc opts ->
                  List.iter (fun (k, v) -> row 4 ("option " ^ k) (str v)) opts
              | _ -> ());
            (* Queue depths and anything else this renderer knows nothing
               about. *)
            List.iter
              (fun (k, v) ->
                let is_bytes =
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
                  | ( ( "type" | "shared" | "reachable" | "socketPath" | "error"
                      | "frontend" | "pid" | "uptimeSeconds" | "cpuSeconds"
                      | "rssBytes" | "traffic" | "bytesRead" | "bytesWritten"
                      | "bytesReadPerSec" | "bytesWrittenPerSec" | "openHandles"
                      | "filesOpened" | "metaLocked" | "metaWaiting" | "options"
                      | "readOnly" | "shares" ),
                      _ ) ->
                      ()
                  | _, `String s -> row 4 k s
                  | _, `Int n when is_bytes -> row 4 k (Metrics.human_bytes n)
                  | _, `Int n -> row 4 k (string_of_int n)
                  | _, `Bool bo -> row 4 k (string_of_bool bo)
                  | _, v -> row 4 k (Yojson.Safe.to_string v))
              (match f with `Assoc fields -> fields | _ -> [])
          end)
        (match mem d "frontends" with `List l -> l | _ -> []);
      List.iter
        (fun m ->
          line 2 "Backend %s (%s, %s)"
            (str (mem m "name"))
            (str (mem m "type"))
            (str (mem m "role"));
          (* So "which bucket is this?" has an answer. *)
            (match mem m "config" with
            | `Assoc fields when fields <> [] ->
                List.iter (fun (k, v) -> row 4 k (str v)) fields
            | _ -> ());
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
          (* One syscall, so unlike the counts below this is on every request. *)
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
                (* Neither "could not look" nor "not counted yet" may read as
                   "holds nothing". *)
                  match (mem t "error", mem t "counting") with
                  | `String e, _ -> row 4 "holds" ("could not count: " ^ e)
                  | _, `Bool true -> row 4 "holds" "counting in the background"
                  | _ ->
                      (* The "~" keeps a sampled figure from reading as a counted
                         one; how it was sampled is in the JSON. *)
                      let approx =
                        if mem t "chunksFromShards" = `Null then "" else "~"
                      in
                      row 4 "holds"
                        (Printf.sprintf "%d manifests, %s%d chunks, %s%s%s"
                           (int_of (mem t "manifests"))
                           approx
                           (int_of (mem t "chunks"))
                           approx
                           (Metrics.human_bytes (int_of (mem t "chunkBytes")))
                           (match mem t "sampledSecondsAgo" with
                             | `Null -> ""
                             | age ->
                                 Printf.sprintf ", as of %s ago"
                                   (duration (num age))))))
        (match mem d "backends" with `List l -> l | _ -> []))
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
