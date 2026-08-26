(* What a running tsync process can say about itself when something is wrong.

   One process's half of the report: its own counters, and the domains it holds.
   Assembling several of these into a machine's report — and rendering it — is
   {!Status_report}'s.

   Everything here is in-process state or a bounded read, except [?totals:true],
   which reaches into the store and is opt-in for that reason. *)

open Lwt.Syntax

(* Set again in a forked child ({!restart}), which is a new process whose uptime
   is its own: this binding is evaluated once, in the launcher, before it forks,
   so every frontend would otherwise report the launcher's. *)
let started_at = ref (Unix.gettimeofday ())
let restart () = started_at := Unix.gettimeofday ()

let level_name = function
  | `debug -> "debug"
  | `info -> "info"
  | `warn -> "warn"
  | `err -> "err"

(* A domain's journal is unbounded and this is a diagnosis page. *)
let journal_sample = 1000

(* Enough that a store in real trouble reads as such rather than as a handful,
   and bounded because a listing that grew with the damage would make the report
   worse exactly when it matters most. *)
let corrupted_sample = 1000

(* The frontend answering this request, as a process.

   At the top rather than under a domain, since a frontend need not belong to
   one: an http-proxy listener's figures cover every domain it serves at once,
   listed in [serves]. A fuse mount is per-domain and appears again in that
   domain's [frontends]. *)
let self_json ?(extra = []) () =
  let uptime = Unix.gettimeofday () -. !started_at in
  let cpu = Metrics.cpu_seconds () in
  let gc = Metrics.gc_stats () in
  let lwt = Metrics_lwt.stats () in
  let mem = Metrics.mem_stats () in
  [
    ( "server",
      `Assoc
        ([
           ("hostname", `String (Unix.gethostname ()));
           ("pid", `Int (Unix.getpid ()));
           ("startedAt", `Float !started_at);
           ("uptimeSeconds", `Float uptime);
         ]
        @ extra) );
    ( "process",
      `Assoc
        [
          ("cpuSeconds", `Float cpu);
          ( "cpuPercentAvg",
            `Float (if uptime > 0. then 100. *. cpu /. uptime else 0.) );
          ("rssBytes", `Int mem.Metrics.rss);
          (* Swapped-out anonymous pages are still this process's own, so
             resident alone understates it by whatever the kernel pushed out. *)
          ("privateBytes", `Int mem.Metrics.private_);
          ("swappedBytes", `Int mem.Metrics.swapped);
          ("heapBytes", `Int gc.Metrics.heap_bytes);
          ("topHeapBytes", `Int gc.Metrics.top_heap_bytes);
          ("minorCollections", `Int gc.Metrics.minor_collections);
          ("majorCollections", `Int gc.Metrics.major_collections);
        ] );
    ( "backend",
      `Assoc
        [
          ("retries", `Int (Metrics.retries ()));
          ("timeouts", `Int (Metrics.timeouts ()));
          ("failures", `Int (Metrics.failures ()));
        ] );
    ( "pools",
      `List
        (List.map
           (fun (name, in_flight, waiting, limit) ->
             `Assoc
               [
                 ("name", `String name);
                 ("inFlight", `Int in_flight);
                 ("waiting", `Int waiting);
                 ("max", `Int limit);
               ])
           (Io_lwt.Bounded.totals ())) );
    ( "lwt",
      `Assoc
        [
          ("readableFds", `Int lwt.Metrics_lwt.readable_fds);
          ("writableFds", `Int lwt.Metrics_lwt.writable_fds);
          ("timers", `Int lwt.Metrics_lwt.timers);
          ("poolSize", `Int lwt.Metrics_lwt.pool_size);
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
  module L = Chunk_layout.Make (C)
  module D = Data.Make (C) (R)
  module Fs = File_store.Make (C)
  module Collection = Collection.Make (C)
  module J = Journal.Make (C)
  module W = Wal_lwt.Make (C)
  module Cor = Corruption.Make (C)

  let int_opt = function Some n -> `Int n | None -> `Null

  (* Deadline for the whole answer, retries included: a backend's own ladder
     backs off to 20s, which is right for work that must land and wrong for a
     health check the first round trip already answered. *)
  let probe_timeout = 10.

  let unreachable exn =
    let detail =
      match exn with
        | exn when Io_lwt.Clock.is_timeout exn ->
            Printf.sprintf "no answer within %.0fs" probe_timeout
        | exn -> Printexc.to_string exn
    in
    `String detail

  (* Fetching the cursor — one small object at a known key — is the whole probe:
     any answer, including a miss, means the store is reachable. Deliberately not
     a listing: a [local] backend walks its whole tree before honouring
     [max_keys]. The body comes back too, since the journal section wants it. *)
  let probe (module B : Backend.S) =
    let t0 = Unix.gettimeofday () in
    Lwt.catch
      (fun () ->
        let+ cursor =
          Lwt_unix.with_timeout probe_timeout (fun () ->
              B.get_opt ~key:C.cursor_key ())
        in
        let ms = 1000. *. (Unix.gettimeofday () -. t0) in
        ( [("reachable", `Bool true); ("latencyMs", `Float ms); ("error", `Null)],
          cursor ))
      (fun exn ->
        Lwt.return
          ( [
              ("reachable", `Bool false);
              ("latencyMs", `Null);
              ("error", unreachable exn);
            ],
            None ))

  (* [behind] is what a sync pass would still have to do, our own entries
     excluded. *)
  let journal ~cursor (module B : Backend.S) =
    Lwt.catch
      (fun () ->
        let+ entries =
          Lwt_unix.with_timeout probe_timeout (fun () ->
              B.list_prefix ~max_keys:(journal_sample + 1)
                ~prefix:C.journal_prefix ())
        in
        let my_uuid = J.client_uuid () in
        let last = Fs.read_last_sync_key () in
        let keys =
          List.filter_map
            (fun (e : Backend.file_entry) ->
              Journal.Entry_key.of_string (Stored_key.to_string e.key))
            entries
        in
        let behind =
          List.filter
            (fun ek ->
              (match last with
                | None -> true
                | Some last -> Journal.Entry_key.compare ek last > 0)
              && Journal.Entry_key.client_uuid ek <> my_uuid)
            keys
        in
        `Assoc
          [
            ("entries", `Int (List.length keys));
            ("behind", `Int (List.length behind));
            ("truncated", `Bool (List.length keys > journal_sample));
            ( "cursor",
              match cursor with
                | Some c -> `String (String.trim c)
                | None -> `Null );
            ( "lastSync",
              match last with
                | Some k -> `String (Journal.Entry_key.to_string k)
                | None -> `Null );
          ])
      (fun exn -> Lwt.return (`Assoc [("error", unreachable exn)]))

  (* Chunks the store found were not what their names say ({!Corruption}).

     Beside [journal] rather than inside [totals]: one bounded listing of a
     prefix that is empty on a healthy store, where [totals] exists because
     counting chunks walks the whole namespace. It costs a round trip per member
     per report, and a report is asked for — [tsync status], the menu's Stats
     submenu when it opens — not polled.

     [checked] is the field that matters. A store nothing verifies lists no
     markers, and so does a store with nothing wrong; printing both as zero
     would turn "nobody looked" into a clean bill of health. *)
  let corrupted m =
    Lwt.catch
      (fun () ->
        let+ found =
          Lwt_unix.with_timeout probe_timeout (fun () ->
              Cor.member_entries ~max_keys:(corrupted_sample + 1) m)
        in
        match found with
          | `Unverified -> `Assoc [("checked", `Bool false)]
          | `Entries es ->
              `Assoc
                [
                  ("checked", `Bool true);
                  ("chunks", `Int (List.length es));
                  ("truncated", `Bool (List.length es > corrupted_sample));
                ])
      (fun exn -> Lwt.return (`Assoc [("error", unreachable exn)]))

  (* Manifests, chunks and bytes held by the store. Reading either namespace
     whole grows with the domain, so the chunk figure is sampled (see
     [count_chunks]) unless [~exact].

     Never counted while a request waits: a request serves the last sample with
     its age, and a sample stands until [~reload], so walking a store is always
     something someone chose. *)
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
        let k = Stored_key.to_string e.Backend.key in
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
            let prefix = L.shard_prefix (Chunk_layout.shard_name (i * step)) in
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
        let* listed = B.list_prefix ~prefix:C.domain_prefix () in
        let manifests =
          List.filter
            (fun (e : Backend.file_entry) ->
              Stored_key.is_child_object e.Backend.key)
            listed
        in
        (* Manifests are keyed by folder id, not hashed, so nothing is evenly
           spread to sample: this count stays a full walk. It is also the smaller
           of the two, one object per file. *)
        let* chunks = count_chunks ~exact (module B) in
        (* Mid-collection the chunk prefix holds only what has been marked so
           far, so these figures are reported as a floor rather than a count. *)
        let+ run = Collection.read_run () in
        let collecting =
          match run with
            | None -> []
            | Some r ->
                [
                  ( "chunksPartial",
                    `String
                      (Printf.sprintf "collection in progress (%s)"
                         (Collection.string_of_phase r.Collection.phase)) );
                ]
        in
        `Assoc
          ((("manifests", `Int (List.length manifests)) :: chunks) @ collecting))
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
    match Option.bind m.Backend.local_path Io_lwt.Fs.disk_space with
      | None -> []
      | Some { Io_lwt.Fs.avail; total; _ } ->
          [
            ( "disk",
              `Assoc
                [
                  ("availableBytes", `Int (Int64.to_int avail));
                  ("totalBytes", `Int (Int64.to_int total));
                ] );
          ]

  let member_json ~totals ~exact ~reload (m : Backend.member) =
    let* probed, cursor = probe m.Backend.backend in
    let cursor = Option.map Bigstring.to_string cursor in
    let* jrnl = journal ~cursor m.Backend.backend in
    let+ corrupt = corrupted m in
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
    (* Same keys and same units as the process-wide [traffic] row, so a reader
       comparing one store against the whole moves between figures that mean the
       same thing. Absent for a store with no link, rather than zeroed. *)
    let traffic =
      match m.Backend.traffic with
        | None -> []
        | Some { Backend.uploaded; downloaded } ->
            [
              ( "traffic",
                `Assoc
                  [
                    ("bytesUploaded", `Int (Metrics.total uploaded));
                    ("bytesDownloaded", `Int (Metrics.total downloaded));
                    ( "uploadBytesPerSec",
                      `Int (int_of_float (Metrics.rate uploaded)) );
                    ( "downloadBytesPerSec",
                      `Int (int_of_float (Metrics.rate downloaded)) );
                  ] );
            ]
    in
    let deferred =
      match (m.Backend.pending, m.in_flight, m.degraded) with
        | Some queued, Some in_flight, Some degraded ->
            [
              ( "deferred",
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
       :: ("role", `String (Conf_parsing.role_name m.role))
       :: ( "config",
            `Assoc (List.map (fun (k, v) -> (k, `String v)) m.Backend.config) )
       :: probed
      @ [("journal", jrnl); ("corrupted", corrupt)]
      @ disk_json m @ traffic @ deferred @ tot)

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
      Lwt.catch (fun () -> Io_lwt.Fs.readdir_list dir) (fun _ -> Lwt.return_nil)
    in
    Lwt_list.fold_left_s
      (fun acc name ->
        let path = Filename.concat dir name in
        let* is_dir = Io_lwt.Fs.is_directory path in
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

  (* Broken down by state, and by the last failure when there was one: "295
     unpublished entries" says a number, "295 intent, oldest failed permanent:
     forbidden" says what to do about it. *)
  let wal_json () =
    Lwt.catch
      (fun () ->
        let+ records = W.list () in
        let count state =
          List.length (List.filter (fun (_, r) -> r.Wal.state = state) records)
        in
        let stuck =
          List.filter_map (fun (_, r) -> r.Wal.last_error) records
          |> List.filter (fun (kind, _) -> kind = Retry.Permanent)
        in
        `Assoc
          [
            ("pending", `Int (List.length records));
            ("intent", `Int (count Wal.Intent));
            ("prepared", `Int (count Wal.Prepared));
            ("executed", `Int (count Wal.Executed));
            ("stuck", `Int (List.length stuck));
            ( "lastError",
              match stuck with
                | (_, detail) :: _ -> `String detail
                | [] -> `Null );
          ])
      (fun exn ->
        Lwt.return (`Assoc [("error", `String (Printexc.to_string exn))]))

  (* [extra] and [frontends] are what only the calling frontend knows. A
     per-domain frontend (a fuse mount) is its own process and carries its own
     cpu and transfer figures; a shared listener (the http-proxy) contributes
     only its per-domain settings here, reporting itself once at the top. *)
  let domain_json ?(totals = false) ?(exact = false) ?(reload = false)
      ?(extra = []) ?(frontends = []) () =
    let* cache = cache_json ~totals in
    let* wal = wal_json () in
    let+ backends =
      Lwt_list.map_p (member_json ~totals ~exact ~reload) C.members
    in
    `Assoc
      (config_json @ extra
      @ [
          ("cache", cache);
          ("wal", wal);
          ("frontends", `List frontends);
          ("backends", `List backends);
        ])
end
