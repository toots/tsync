(* Which reported jobs a status listing still believes.

   The registry is fed by processes it does not control and cannot ask
   anything: a command that is SIGKILLed mid-import sends no goodbye, and its
   row would otherwise sit in [tsync status] claiming to be running for as long
   as the daemon lives. So liveness is asserted against a real second process
   that is really killed, rather than a stand-in that would prove only that the
   pruning code runs.

   The merge half guards a trap of its own: on macOS one daemon answers for
   every domain it serves, so a caller collects several reports carrying the
   same job table, and merging them naively lists one import once per domain it
   is not running against. What a reader finally sees is asserted last, since
   every field above reaches them through a format string that reads a name and
   a type it is given rather than one it checks. *)

open Check

let job_json ?(state = "running") ?(started = 1000.) ~kind pid =
  `Assoc
    [
      ("kind", `String kind);
      ("pid", `Int pid);
      ("startedAt", `Float started);
      ("state", `String state);
    ]

(* As the IPC arm does: what the registry decides with is passed apart from the
   payload it merely stores. *)
let record ?state ?started ~kind pid =
  let report = job_json ?state ?started ~kind pid in
  Job_registry.record ~pid
    ~started:(Option.value started ~default:1000.)
    ~interval:10.
    ~finished:(Option.value state ~default:"running" <> "running")
    report

let pids () =
  List.map
    (fun j -> match Yojson.Safe.Util.member "pid" j with `Int p -> p | _ -> 0)
    (Job_registry.live ())

(* A child that outlives the assertions on it, so "alive" is a fact about a
   process rather than about timing. *)
let spawn_sleeper () =
  match Unix.fork () with
    | 0 ->
        Unix.sleep 120;
        exit 0
    | pid -> pid

(* Reaped before the registry is asked: a zombie still answers [kill 0], so a
   test that skipped this would pass with the liveness check doing nothing. *)
let kill_and_reap pid =
  Unix.kill pid Sys.sigkill;
  ignore (Unix.waitpid [] pid)

let () =
  case "a live process is listed, a dead one is not";
  let live_pid = spawn_sleeper () and dead_pid = spawn_sleeper () in
  record ~kind:"import" live_pid;
  record ~kind:"gc" dead_pid;
  check "both are listed while both are running"
    (List.mem live_pid (pids ()) && List.mem dead_pid (pids ()));
  kill_and_reap dead_pid;
  check "the killed job is dropped" (not (List.mem dead_pid (pids ())));
  check "the surviving job is kept" (List.mem live_pid (pids ()));

  case "a finished job outlives its process";
  let done_pid = spawn_sleeper () in
  record ~kind:"gc" ~state:"done" done_pid;
  kill_and_reap done_pid;
  check "a job that said it was done stays visible"
    (List.mem done_pid (pids ()));
  record ~kind:"gc" ~state:"failed" live_pid;
  check "and so does one that said it failed" (List.mem live_pid (pids ()));

  case "a second report replaces the first";
  record ~kind:"import" live_pid;
  record ~kind:"import" ~started:2000. live_pid;
  check "one row per process"
    (List.length (List.filter (fun p -> p = live_pid) (pids ())) = 1);
  kill_and_reap live_pid;

  case "merging reports from one process answering for several domains";
  let with_jobs jobs domain =
    `Assoc
      [
        ("server", `Assoc [("pid", `Int 1)]);
        ("domains", `List [`Assoc [("name", `String domain)]]);
        ("jobs", `List jobs);
      ]
  in
  let a = job_json ~kind:"import" 111 and b = job_json ~kind:"gc" 222 in
  let merged = Diagnostics.merge [with_jobs [a] "one"; with_jobs [b] "two"] in
  let job_pids j =
    match Yojson.Safe.Util.member "jobs" j with
      | `List l ->
          List.map
            (fun j ->
              match Yojson.Safe.Util.member "pid" j with `Int p -> p | _ -> 0)
            l
      | _ -> []
  in
  check "jobs from every report survive the merge" (job_pids merged = [111; 222]);
  check "and both domains do too"
    (match Yojson.Safe.Util.member "domains" merged with
      | `List l -> List.length l = 2
      | _ -> false);
  let shared = Diagnostics.merge [with_jobs [a] "one"; with_jobs [a] "two"] in
  check "the same job reported twice is listed once" (job_pids shared = [111]);
  let none = Diagnostics.merge [with_jobs [] "one"; with_jobs [] "two"] in
  check "and no jobs is an empty list, not a missing key"
    (Yojson.Safe.Util.member "jobs" none = `List []);

  case "what a reader is shown";
  let rendered ?error ?(progress = []) ~state () =
    Diagnostics.text
      (`Assoc
         [
           ("server", `Assoc [("frontend", `String "fuse")]);
           ("domains", `List []);
           ( "jobs",
             `List
               [
                 `Assoc
                   ([
                      ("kind", `String "import");
                      ("pid", `Int 4242);
                      ("state", `String state);
                      ("startedAt", `Float (Unix.gettimeofday () -. 3720.));
                      (* Elapsed comes from the reporting process, whose clock
                         is not the clock of whoever renders this. *)
                      ("uptimeSeconds", `Float 3720.);
                      ("target", `String "/media/stage");
                      ("current", `String "big.mov");
                    ]
                   @ progress
                   @ [
                       ( "counters",
                         `List
                           [
                             `List [`String "files"; `Int 30433];
                             `List [`String "planned"; `Int 61956];
                           ] );
                       ( "memory",
                         `Assoc
                           [
                             ("rssBytes", `Int 113246208);
                             ("swappedBytes", `Int 41943040);
                           ] );
                       ( "gc",
                         `Assoc
                           [
                             ("heapBytes", `Int 78643200);
                             ("liveBytes", `Int 43008000);
                           ] );
                       ( "traffic",
                         `Assoc
                           [
                             ("bytesUploaded", `Int 756640839270);
                             ("uploadBytesPerSec", `Int 8178892);
                             ("bytesDownloaded", `Int 41231872);
                             ("downloadBytesPerSec", `Int 2097152);
                             ("chunksHashed", `Int 2500);
                           ] );
                       ( "deferred",
                         `Assoc
                           [
                             ("queued", `Int 207);
                             ("inFlight", `Int 3);
                             ("degraded", `Bool true);
                           ] );
                       ( "pools",
                         `List
                           [
                             `Assoc
                               [
                                 ("name", `String "chunk buffers");
                                 ("inFlight", `Int 4);
                                 ("max", `Int 4);
                                 ("waiting", `Int 12);
                               ];
                           ] );
                       ( "backend",
                         `Assoc
                           [
                             ("retries", `Int 91);
                             ("timeouts", `Int 87);
                             ("failures", `Int 0);
                           ] );
                     ]
                   @
                     match error with
                     | None -> []
                     | Some e -> [("error", `String e)]);
               ] );
         ])
  in
  let progress =
    [
      ( "progress",
        `Assoc
          [
            ("bytesTotal", `Int 9019431322);
            ("bytesDone", `Int 1288490188);
            ("bytesSkipped", `Int 2254857830);
            ("bytesFailed", `Int 0);
            ("bytesRemaining", `Int 5476083304);
            ("bytesPerSec", `Int 8178892);
            ("etaSeconds", `Float 669.5);
            ( "current",
              `Assoc
                [("bytesDone", `Int 536870912); ("bytesTotal", `Int 4294967296)]
            );
          ] );
    ]
  in
  let running = rendered ~state:"running" ~progress () in
  let has_in text s =
    let re = Str.regexp_string s in
    try
      ignore (Str.search_forward re text 0);
      true
    with Not_found -> false
  in
  let has s = has_in running s in
  check "the job is named, with its pid and how long it has run"
    ~why:(fun () -> running)
    (has "import  pid 4242  running 1h 2m  /media/stage");
  check "what it is on right now, and how far into it the run is"
    ~why:(fun () -> running)
    (has "big.mov — 512.0 MB of 4.0 GB (12%)");
  check "the bytes behind and ahead of the run, with what it will take"
    ~why:(fun () -> running)
    (has
       "1.2 GB of 8.4 GB (14%), 5.1 GB left at 7.8 MB/s, ~11m 9s — 2.1 GB \
        already in the domain");
  (* A command counting entries and not bytes must render as it always has. *)
  let countless = rendered ~state:"running" () in
  check "a job reporting no bytes says only what it is on"
    ~why:(fun () -> countless)
    (has_in countless "current" && not (has_in countless "progress"));
  check "its counters, in the order it published them"
    ~why:(fun () -> running)
    (has "30433 files, 61956 planned");
  check "live words beside the heap, which is the pair that answers retention"
    ~why:(fun () -> running)
    (has "108.0 MB rss + 40.0 MB swapped, 75.0 MB heap, 41.0 MB live");
  check "the deferred queue"
    ~why:(fun () -> running)
    (has "207 queued, 3 in flight");
  check "a dropped write, which is a call to action rather than a figure"
    ~why:(fun () -> running)
    (has "run tsync mirror");
  check "a pool that is full, and what is queued behind it"
    ~why:(fun () -> running)
    (has "chunk buffers 4/4 (12 waiting)");
  check "retries, with timeouts counted apart"
    ~why:(fun () -> running)
    (has "91 retries (87 timeouts)");
  (* A rate in both directions: a total alone cannot tell a transfer that is
     moving from one that has stopped, which is the question asked of a mirror
     whose direction is down. *)
  check "traffic, each direction with its own rate"
    ~why:(fun () -> running)
    (has "up 704.7 GB (7.8 MB/s), down 39.3 MB (2.0 MB/s), 2500 chunks hashed");

  (* The elapsed figure is the same either way, so a job that has stopped must
     not leave it reading as an age. *)
  let dead = rendered ~state:"failed" ~error:"disk full" () in
  check "a job that died says so, and what killed it"
    ~why:(fun () -> dead)
    (has_in dead "import  pid 4242  failed, ran 1h 2m  /media/stage: disk full");

  (* Counted, so a suite that stopped exercising anything fails rather than
     passing quietly. *)
  report ~expected:22 ()
