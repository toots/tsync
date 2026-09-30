open Tsync_status.Status_report
module Uplink = Tsync_store.Uplink

let mib n = n * 1024 * 1024

let usage ~cpu ~private_ ~heap : usage =
  {
    cpu_seconds = 12.;
    cpu_percent = cpu;
    cpu_percent_avg = cpu;
    rss_bytes = private_;
    private_bytes = private_;
    swapped_bytes = 0;
    anonymous_bytes = Some private_;
    file_backed_bytes = Some (mib 9);
    heap_bytes = heap;
    top_heap_bytes = heap;
    minor_collections = 10;
    major_collections = 1;
  }

let self ?traffic ?(recent = []) ?(uplinks = []) ~role ~pid ~uptime ~serves () :
    self =
  {
    server =
      {
        hostname = "example";
        pid;
        started_at = 0.;
        uptime;
        load_avg = (if role = "supervisor" then Some 0.42 else None);
        role;
        serves;
      };
    usage = usage ~cpu:1.25 ~private_:(mib 61) ~heap:(mib 18);
    uplinks;
    traffic;
    recent_errors = recent;
  }

let settings : settings =
  {
    versioning = true;
    symlinks = `Keep;
    chunk_size = mib 8;
    chunk_size_default = true;
    cache_chunk_size = mib 16;
    max_uploads = 4;
    max_chunk_buffers = 4;
    max_downloads = 8;
    read_only = true;
  }

let idle_sync =
  {
    hold = None;
    mark_age = Some 12.;
    unapplied_entries = 0;
    unapplied_reason = None;
    parked_metadata = 0;
  }

let clean_wal =
  { intent = 0; prepared = 0; executed = 0; stuck = 0; last_error = None }

let no_queues =
  { pending_files = 0; pending_metadata = 0; in_flight = []; bytes_owed = 0 }

let fuse : frontend =
  {
    kind = "fuse";
    pid = Some 101;
    mount = Some "/home/u/tsync/Media";
    port = None;
    open_handles = Some 0;
    bytes_read = Some 0;
    bytes_written = Some 0;
    unanswered = false;
  }

let gcs : backend =
  {
    name = "gcs";
    kind = "gcs";
    role = "main";
    link = Some "wan";
    config = [("bucket", "media-bucket"); ("credentials", "***")];
    reach = Reachable { latency_ms = 51.2 };
    journal = Entries { entries = 1444; behind = 0 };
    corrupted = Not_checked "no verification has run";
    health = Up;
    disk = None;
    copies = Some { owed = 0; parked = 0; rate = 0.; current = None };
    traffic =
      Some { up_bytes = 0; up_rate = 0.; down_bytes = 92; down_rate = 4. };
  }

let wan : Uplink.link_status =
  {
    name = "wan";
    state = `Steady;
    limit = Measured;
    max_rate = None;
    rate = 2936012.8;
    capacity = Some 3670016.;
    achieved = 2831155.2;
    base_delay_ms = Some 31.;
    queueing_delay_ms = 2.4;
    in_flight = 0;
    window = 0.;
    drops = 0;
    headroom = 0.8;
    target_delay_ms = 50.;
    waiting = 0;
    mode = `Owner;
    own_rate = Some 65536.;
    lessees =
      [
        {
          pid = 101;
          rate = 2936012.8;
          in_flight = 0;
          waiting = 0;
          held_back = false;
          probe_ms = Some 31.;
        };
      ];
  }

let healthy : machine =
  {
    host = "example";
    domains =
      [
        Answered
          {
            name = "Media";
            paused = false;
            main_offline = false;
            settings;
            sync = idle_sync;
            cache =
              {
                chunks = 7494;
                bytes = 10630044876;
                pinned_bytes = 0;
                max_cache = Some 10737418240;
              };
            wal = clean_wal;
            queues = no_queues;
            frontends = [fuse];
            backends = [gcs];
          };
      ];
    processes =
      [
        {
          role = "supervisor";
          pid = Some 100;
          serves = [];
          error = None;
          self =
            Some (self ~role:"supervisor" ~pid:100 ~uptime:671. ~serves:[] ());
        };
        {
          role = "owner";
          pid = Some 101;
          serves = ["Media"];
          error = None;
          self =
            Some
              (self ~role:"owner" ~pid:101 ~uptime:670. ~serves:["Media"]
                 ~uplinks:
                   [
                     {
                       wan with
                       mode = `Leased;
                       state = `Leased;
                       rate = 2936012.8;
                       in_flight = 8389632;
                       waiting = 1;
                       own_rate = None;
                       lessees = [];
                     };
                   ]
                 ~traffic:
                   {
                     up_bytes = 0;
                     up_rate = 0.;
                     down_bytes = 1946;
                     down_rate = 9.;
                   }
                 ());
        };
      ];
    uplinks = [wan];
    jobs = [];
    warnings = [];
  }

let degraded : machine =
  {
    host = "example";
    domains =
      [
        Answered
          {
            name = "Files";
            paused = true;
            main_offline = true;
            settings =
              {
                settings with
                symlinks = `Follow;
                chunk_size = mib 4;
                chunk_size_default = false;
                max_uploads = 1;
                max_chunk_buffers = 1;
                max_downloads = 1;
                read_only = false;
              };
            sync =
              {
                hold = Some "no last-sync mark; holding until a rebuild";
                mark_age = None;
                unapplied_entries = 2;
                unapplied_reason =
                  Some "a peer's folder rename meets a local edit";
                parked_metadata = 1;
              };
            cache =
              {
                chunks = 1088;
                bytes = 10200547328;
                pinned_bytes = 331769446;
                max_cache = Some 214748364800;
              };
            wal =
              {
                intent = 1;
                prepared = 1;
                executed = 1;
                stuck = 1;
                last_error = Some "DEADLINE: store did not answer";
              };
            queues =
              {
                pending_files = 3;
                pending_metadata = 1;
                in_flight = ["Photos/a.jpg"; "Photos/b.jpg"];
                bytes_owed = mib 50;
              };
            frontends =
              [
                {
                  fuse with
                  kind = "http-proxy";
                  pid = None;
                  mount = None;
                  port = Some 5446;
                  unanswered = true;
                };
              ];
            backends =
              [
                {
                  gcs with
                  config = [("bucket", "files")];
                  reach = Unreachable "DNS lookup failed";
                  journal = Counting;
                  corrupted = Checked { chunks = 3; truncated = true };
                  copies =
                    Some
                      {
                        owed = 1204;
                        parked = 2;
                        rate = 0.;
                        current =
                          Some
                            {
                              job =
                                "tsync/Files/manifests/d62e6a4d741d649c/8efbae2a";
                              path =
                                Some
                                  "Music Production/Sabertooth \
                                   Swing/Assets/Sunday Swing June 14 \
                                   2026/2026-06-14 \
                                   Sabertooth/media/SABR_260614_B01/XDROOT/Clip/ALLWAYS0010.MXF";
                              size = Some 5153960755;
                              chunks = 615;
                              checked = 205;
                              sent = 1719664640;
                              elapsed = 3600.;
                              eta = Some 7200.;
                            };
                      };
                  health =
                    Down
                      {
                        held_for = 42.;
                        failures = 5;
                        reason = "connection refused";
                      };
                  traffic = None;
                };
                {
                  gcs with
                  name = "disk";
                  kind = "local";
                  role = "replica";
                  link = None;
                  config = [("path", "/srv/tsync")];
                  reach = Reachable { latency_ms = 0.4 };
                  journal = Unreadable "permission denied";
                  corrupted = Checked { chunks = 0; truncated = false };
                  disk =
                    Some
                      {
                        free_bytes = 1099511627776;
                        total_bytes = 10995116277760;
                      };
                  traffic = None;
                };
              ];
          };
        Unanswered "Media";
      ];
    processes =
      [
        {
          role = "supervisor";
          pid = Some 100;
          serves = [];
          error = None;
          self =
            Some (self ~role:"supervisor" ~pid:100 ~uptime:90061. ~serves:[] ());
        };
        {
          role = "owner";
          pid = Some 102;
          serves = ["Media"];
          error = Some "connection refused";
          self = None;
        };
      ];
    uplinks = [];
    jobs =
      [
        {
          pid = 300;
          kind = "import";
          domain = Some "Files";
          state = `Running;
          error = None;
          progress =
            Some
              {
                total = 5000;
                skipped = 0;
                finished = 1200;
                handled = 1200;
                remaining = 3800;
                eta = Some 600.;
              };
        };
      ];
    warnings =
      [
        {
          level = Warn;
          message = "copy replica: parked";
          count = 3;
          first = 900.;
          last = 990.;
          pids = [101];
        };
        {
          level = Err;
          message = "cannot bridge the journal";
          count = 1;
          first = 500.;
          last = 500.;
          pids = [101];
        };
      ];
  }

let () =
  List.iter
    (fun (name, m) ->
      Printf.printf "== %s\n%s\n" name
        (Tsync_status.Status_text.render ~now:1000. m);
      Printf.printf "survives the wire: %b\n\n"
        (machine_of_yojson
           (Yojson.Safe.from_string
              (Yojson.Safe.to_string (machine_to_yojson m)))
        = Ok m))
    [("healthy", healthy); ("degraded", degraded)]
