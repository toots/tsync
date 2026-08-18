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
   is not running against. *)

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

  (* Counted, so a suite that stopped exercising anything fails rather than
     passing quietly. What a reader is finally shown is tests/unit/job_render,
     a snapshot: a row is prose, and prose is reviewed whole. *)
  report ~expected:10 ()
