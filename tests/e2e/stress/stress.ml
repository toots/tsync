(* Concurrent load over two FUSE mounts of one domain, judged against an oracle.

   The two-client scenarios in [tests/scenario/sync] drive File_ops directly and
   are deterministic. This drives two real mounts with real syscalls from many
   threads at once, which is where the kernel's own caches, the folder-id race
   and the deferred targets all meet. That combination is what surfaced the
   stranded-namespace bug, and none of the hermetic suites could have.

   The namespace is split so most of it has a strict expectation. a/ is only
   touched by client A and b/ only by B, and a per-path lock keeps one path's
   operations in a straight line, so its legal end states are: the state after
   the last acked operation, plus the state after every interrupted one that
   follows. shared/ is written by both and carries only the weak expectation
   that whatever is there is something somebody wrote.

   Everything random comes from one seed, printed on every run. A failure that
   cannot be replayed is a failure nobody can act on.

   Manifests are read with {!Chunk_table} and stores with {!Backend}, never with
   a second implementation of either: a checker that parses the format its own
   way drifts from the product and starts issuing confident wrong verdicts, and
   one that lists a bucket with another client is not testing this one. *)

open E2e

let env = { domain = "tsync-stress"; port = 8791; secret = "stress-secret" }

let unmount mount =
  sh "fusermount3 -u %s 2>/dev/null || umount %s 2>/dev/null"
    (Filename.quote mount) (Filename.quote mount)

(* {1 The journal the oracle reads} *)

type outcome = Acked | Interrupted | Failed_op
type op = Write of string | Delete | Rename_away | Rename_onto of string
type record = { path : string; op : op; outcome : outcome; at : float }

let journal : record list ref = ref []
let journal_lock = Mutex.create ()
let ops_run = ref 0

let record r =
  Mutex.lock journal_lock;
  journal := r :: !journal;
  incr ops_run;
  Mutex.unlock journal_lock

(* Held while a fault is in flight, so work overlapping one is not judged
   against the strict expectation. *)
let fault_in_flight = ref false
let faults_landed = ref 0
let load_running = ref true

(* One daemon this run started, so a fault can take it away and bring it back. *)
type daemon = {
  label : string;
  home : string;
  args : string list;
  mutable pid : int;
}

(* {1 Load} *)

let locks : (string, Mutex.t) Hashtbl.t = Hashtbl.create 64
let locks_guard = Mutex.create ()

let path_lock p =
  Mutex.lock locks_guard;
  let m =
    match Hashtbl.find_opt locks p with
      | Some m -> m
      | None ->
          let m = Mutex.create () in
          Hashtbl.add locks p m;
          m
  in
  Mutex.unlock locks_guard;
  m

let with_lock m f =
  Mutex.lock m;
  Fun.protect ~finally:(fun () -> Mutex.unlock m) f

let body rnd n =
  (* Compressible but not uniform, so chunk dedup is exercised both ways. *)
  let unit = String.make 977 (Char.chr (97 + Random.State.int rnd 26)) in
  String.init n (fun i -> unit.[i mod 977])

let digest s = String.sub (Digest.to_hex (Digest.string s)) 0 16

(* What an operation did is settled by doing it, which is why the action reports
   its own op rather than being handed one.

   Preparing the op first means deciding it from a look at the filesystem taken
   outside the guard, and in a tree two clients are writing to that look can go
   stale -- or raise -- between the look and the act. It did: a run died on
   [Sys.file_exists p] answering yes and the read that followed finding nothing,
   with the exception escaping [attempt] because OCaml evaluates an argument
   before the call it belongs to. That is the same assumption the product had to
   drop, a decision made from a snapshot no single writer owns.

   The oracle discards [Failed_op] records, so a raise needs no op of its own. *)
let attempt path f =
  let dirty = !fault_in_flight in
  let op, outcome =
    match f () with
      | op -> (op, if dirty || !fault_in_flight then Interrupted else Acked)
      | exception _ -> (Write "", Failed_op)
  in
  record { path; op; outcome; at = Unix.gettimeofday () };
  outcome

let worker ~mount ~ns ~ops ~seed ~wid ~sizes =
  let rnd = Random.State.make [| seed; Hashtbl.hash ns; wid |] in
  for _ = 1 to ops do
    let name = Printf.sprintf "%s/f%02d" ns (Random.State.int rnd 12) in
    let p = Filename.concat mount name in
    let pick = Random.State.int rnd 100 in
    if pick < 45 then begin
      let data =
        body rnd (List.nth sizes (Random.State.int rnd (List.length sizes)))
      in
      with_lock (path_lock name) (fun () ->
          ignore
            (attempt name (fun () ->
                 sh "mkdir -p %s" (Filename.quote (Filename.dirname p));
                 write_file p data;
                 Write (digest data))))
    end
    else if pick < 70 then
      with_lock (path_lock name) (fun () ->
          ignore
            (attempt name (fun () ->
                 (* One read, and the op is whatever it saw. An absent file is
                    an answer, not a failure: it changes nothing, which is what
                    [Write ""] says. *)
                 match read_file p with
                   | data -> Write (digest data)
                   | exception _ -> Write "")))
    else if pick < 85 then begin
      let dst = Printf.sprintf "%s/f%02d" ns (Random.State.int rnd 12) in
      if dst <> name then begin
        let first, second = if name < dst then (name, dst) else (dst, name) in
        with_lock (path_lock first) (fun () ->
            let inner () =
              let moved = ref false in
              let outcome =
                attempt name (fun () ->
                    match Sys.rename p (Filename.concat mount dst) with
                      | () ->
                          moved := true;
                          Rename_away
                      (* The source was already gone, so nothing moved and the
                         path is still judgeable. Recording [Rename_away] here
                         would retire it from the oracle for a move that never
                         happened. *)
                      | exception _ -> Write "")
              in
              (* And the destination only hears about it if a file actually
                 arrived, with the outcome the move actually had -- claiming
                 [Acked] unconditionally told the oracle about writes that never
                 landed. *)
              if !moved then
                record
                  { path = dst; op = Rename_onto name; outcome;
                    at = Unix.gettimeofday () }
            in
            if first = second then inner ()
            else with_lock (path_lock second) inner)
      end
    end
    else
      with_lock (path_lock name) (fun () ->
          ignore
            (attempt name (fun () ->
                 (* Removing a file that is already gone leaves the same state,
                    so it is an outcome rather than a failure. *)
                 (try Sys.remove p with Sys_error _ -> ());
                 Delete)));
    Thread.delay (Random.State.float rnd 0.15)
  done

(* {1 Faults}

   Each opens a window that the journal records, so work caught in one is judged
   as "either outcome is legal" rather than held to what an undisturbed run
   would have produced. Every fault increments a counter, because a mode that
   injected nothing must not be able to report a pass -- a run that tested
   nothing looks exactly like a clean one otherwise. *)

let during_fault what f =
  fault_in_flight := true;
  incr faults_landed;
  Printf.printf "  fault: %s\n%!" what;
  Fun.protect ~finally:(fun () -> fault_in_flight := false) f

(* SIGKILL, not a stop: what has to survive is the process vanishing mid-write,
   which is the case the write-ahead records exist for. *)
let crash_and_restart ~exe d ~after_start =
  during_fault (Printf.sprintf "killing %s" d.label) (fun () ->
      (try Unix.kill d.pid Sys.sigkill with _ -> ());
      (try ignore (Unix.waitpid [] d.pid) with _ -> ());
      Unix.sleepf 1.5;
      d.pid <- spawn_daemon ~args:d.args ~exe ~home:d.home ~label:d.label ();
      after_start d)

let spinners = ref []

let start_pressure () =
  during_fault "cpu load" (fun () ->
      spinners :=
        List.init 4 (fun _ ->
            Unix.create_process "/bin/sh"
              [| "/bin/sh"; "-c"; "while :; do :; done" |]
              Unix.stdin Unix.stdout Unix.stderr))

let stop_pressure () =
  List.iter (fun p -> try Unix.kill p Sys.sigkill with _ -> ()) !spinners;
  List.iter (fun p -> try ignore (Unix.waitpid [] p) with _ -> ()) !spinners;
  spinners := []

(* {1 The oracle} *)

(* Legal end states for a strict path: what stood after the last acked
   operation, plus what every interrupted one after it would have left. A path
   any rename touched is ambiguous by construction and is not judged. *)
let legal_states path =
  let mine =
    List.filter (fun r -> r.path = path) !journal
    |> List.sort (fun a b -> compare a.at b.at)
  in
  if
    List.exists
      (fun r ->
        match r.op with Rename_away | Rename_onto _ -> true | _ -> false)
      mine
  then None
  else begin
    let states = ref [] and cur = ref None in
    List.iter
      (fun r ->
        (match r.op with
          | Write "" -> () (* a read, which changes nothing *)
          | Write h -> cur := Some h
          | Delete -> cur := None
          | _ -> ());
        states := (!cur, r.outcome) :: !states)
      (List.filter (fun r -> r.outcome <> Failed_op) mine);
    let states = List.rev !states in
    let rec from_last_ack acc seen = function
      | [] -> acc
      | (st, Acked) :: tl -> from_last_ack [st] true tl
      | (st, _) :: tl -> from_last_ack (if seen then st :: acc else acc) seen tl
    in
    match states with
      | [] -> None
      | _ -> Some (from_last_ack [None] false states)
  end

(* {1 Checks over the settled domain} *)

let tree mount =
  all_files mount
  |> List.map (fun p ->
      ( String.sub p
          (String.length mount + 1)
          (String.length p - String.length mount - 1),
        try digest (read_file p) with _ -> "UNREADABLE" ))
  |> List.sort compare

(* Every chunk a manifest names, read with the product's own parser. *)
let manifest_chunks path =
  match Chunk_table.of_string (read_file path) with
    | t -> Some (List.init (Chunk_table.count t) (Chunk_table.key t))
    | exception _ -> None

let check_store ~store =
  let files = all_files store in
  let chunk_of p = Filename.basename p in
  let present =
    files |> List.filter (fun p -> contains p "/chunks/") |> List.map chunk_of
  in
  let manifests = manifests ~env ~store in
  check "the load reached the store" (fun () ->
      if manifests = [] then
        failf
          "no manifest under %s -- nothing was actually published, so the \
           checks below verified nothing"
          store);
  List.iter
    (fun m ->
      match manifest_chunks m with
        | None -> () (* a folder marker, not a manifest *)
        | Some keys ->
            let missing =
              List.filter (fun k -> not (List.mem k present)) keys
            in
            check
              (Printf.sprintf "every chunk of %s is present"
                 (Filename.basename m))
              (fun () ->
                if missing <> [] then
                  failf "%d absent, e.g. %s" (List.length missing)
                    (List.hd missing)))
    manifests

let () =
  Printexc.record_backtrace true;
  let seed =
    match Sys.getenv_opt "TSYNC_STRESS_SEED" with
      | Some s -> int_of_string s
      | None -> Random.int 1_000_000
  in
  let ops =
    match Sys.getenv_opt "TSYNC_STRESS_OPS" with
      | Some s -> int_of_string s
      | None -> 60
  in
  Printf.printf "seed %d  (replay with TSYNC_STRESS_SEED=%d)\n%!" seed seed;
  (* After the seed is read: where this run stages is incidental, and tying it
     to the seed gave every replay the same directory to collide in. *)
  Random.self_init ();

  let exe = Filename.concat (Sys.getcwd ()) "_build/default/bin/tsync.exe" in
  let root = scratch_root "tss" in
  let store = Filename.concat root "store" in
  let store_home = Filename.concat root "sh" in
  let home_a = Filename.concat root "ha"
  and home_b = Filename.concat root "hb" in
  let mnt_a = Filename.concat root "mnt-a"
  and mnt_b = Filename.concat root "mnt-b" in
  List.iter
    (fun d -> sh "mkdir -p %s" (Filename.quote d))
    [store; store_home; home_a; home_b; mnt_a; mnt_b];

  let daemons = ref [] in
  let pids () = List.map (fun d -> d.pid) !daemons in
  (* Kept on request, and always kept when something failed: a run that found
     something is exactly the one whose logs, store and mounts you want, and
     they are gone the moment this returns. *)
  let keep = Sys.getenv_opt "TSYNC_STRESS_KEEP" <> None in
  let restore ?(failed = false) () =
    stop_pressure ();
    List.iter stop_daemon (pids ());
    unmount mnt_a;
    unmount mnt_b;
    Unix.sleepf 1.;
    if keep || failed then
      Printf.printf "left in place for inspection: %s\n%!" root
    else sh "rm -rf %s" (Filename.quote root)
  in
  let finish code =
    restore ();
    exit code
  in

  try
    Printf.printf "staging in %s\n%!" root;
    write_config ~home:store_home ~name:"stress-store"
      ~domains:
        [
          domain_json ~env
            ~backends:[local_backend ~path:store]
            ~frontends:[proxy_frontend ~env];
        ];
    let store_d =
      {
        label = "store";
        home = store_home;
        args = [];
        pid = spawn_daemon ~exe ~home:store_home ~label:"store" ();
      }
    in
    daemons := [store_d];
    wait_until ~timeout:30. ~what:"the store to listen" (fun () ->
        Sys.command
          (Printf.sprintf "curl -sf -o /dev/null http://127.0.0.1:%d/" env.port)
        = 0);
    List.iter
      (fun (home, label, mount) ->
        write_config ~home ~name:label
          ~domains:
            [
              domain_json ~env
                ~backends:[proxy_backend ~env]
                ~frontends:[`String "fuse"];
            ];
        (* Without --mount the daemon takes its default under the real HOME,
            leaving these directories empty and every check judging nothing. *)
        let args = ["--mount"; mount] in
        daemons :=
          { label; home; args; pid = spawn_daemon ~args ~exe ~home ~label () }
          :: !daemons)
      [(home_a, "A", mnt_a); (home_b, "B", mnt_b)];
    (* Waiting on a successful write is not enough: it succeeds against the
        empty staging directory before FUSE takes it over, and then the whole
        run judges a plain directory. Wait for the mount itself, then for it to
        accept a write. *)
    let mounted m =
      Sys.command (Printf.sprintf "mountpoint -q %s" (Filename.quote m)) = 0
    in
    List.iter
      (fun mount ->
        wait_until ~timeout:120. ~what:"FUSE to take the directory over"
          (fun () -> mounted mount);
        wait_writable ~mount)
      [mnt_a; mnt_b];

    let mount_of d = if d.label = "A" then mnt_a else mnt_b in
    let remount d =
      if d.label <> "store" then begin
        let m = mount_of d in
        wait_until ~timeout:120. ~what:"the mount to come back" (fun () ->
            mounted m);
        wait_writable ~mount:m
      end
      else
        wait_until ~timeout:60. ~what:"the store to listen again" (fun () ->
            Sys.command
              (Printf.sprintf "curl -sf -o /dev/null http://127.0.0.1:%d/"
                 env.port)
            = 0)
    in
    let fault_mode =
      Option.value (Sys.getenv_opt "TSYNC_STRESS_FAULT") ~default:"none"
    in
    let fault_rnd = Random.State.make [| seed lxor 0x5eed |] in
    let faulter () =
      (* Wait for the load to start, not for a length of time. A fixed delay is
         a guess about how fast the machine is, and the guess was made on the
         machine this was written on: 1.5s lands mid-run there and lands after
         the run on a CI runner with a faster /tmp, where the whole load is over
         first. Every fault cell then reports none landed -- which is what the
         first scheduled run did, across all nine of them.

         Waiting on the first journalled op instead ties the fault to the work
         rather than to the clock, and holds on any machine. *)
      while !load_running && !ops_run = 0 do
        Thread.delay 0.02
      done;
      while !load_running do
        if !load_running then (
          match fault_mode with
            | "crash" ->
                let clients =
                  List.filter (fun d -> d.label <> "store") !daemons
                in
                let d =
                  List.nth clients
                    (Random.State.int fault_rnd (List.length clients))
                in
                (* Unmounted first: a killed daemon leaves the mount as a stub
                    the next one cannot take over. *)
                unmount (mount_of d);
                crash_and_restart ~exe d ~after_start:remount
            | "store" ->
                (* The remote going away and coming back, which is what the
                    deferred targets and the retry ladder are for. *)
                crash_and_restart ~exe store_d ~after_start:remount
            | "load" -> if !spinners = [] then start_pressure ()
            | _ -> ());
        (* Short enough that a run measured in seconds still gets several. *)
        Thread.delay (0.4 +. Random.State.float fault_rnd 1.2)
      done
    in
    let fault_thread =
      if fault_mode = "none" then None else Some (Thread.create faulter ())
    in
    let sizes = [1024; 64 * 1024; 1_200_000] in
    let threads =
      List.concat_map
        (fun (mount, own) ->
          List.init 3 (fun i ->
              Thread.create
                (fun () -> worker ~mount ~ns:own ~ops ~seed ~wid:i ~sizes)
                ())
          @ [
              Thread.create
                (fun () ->
                  worker ~mount ~ns:"shared" ~ops:(ops / 2) ~seed ~wid:99 ~sizes)
                ();
            ])
        [(mnt_a, "a"); (mnt_b, "b")]
    in
    List.iter Thread.join threads;
    load_running := false;
    Option.iter Thread.join fault_thread;
    stop_pressure ();
    Printf.printf "ops journalled: %d, faults landed: %d\n%!" !ops_run
      !faults_landed;
    (* A mode that injected nothing tested nothing it claims to, and its report
        is indistinguishable from a clean run. *)
    check "the faults this run asked for actually landed" (fun () ->
        if fault_mode <> "none" && !faults_landed = 0 then
          failf
            "TSYNC_STRESS_FAULT=%s, none injected -- the run exercised none of \
             what it names"
            fault_mode);
    (* Whatever a fault left down has to be back before the domain can settle. *)
    List.iter
      (fun d ->
        match Unix.waitpid [Unix.WNOHANG] d.pid with
          | 0, _ -> ()
          | _ ->
              d.pid <-
                spawn_daemon ~args:d.args ~exe ~home:d.home ~label:d.label ();
              remount d
          | exception _ -> ())
      (List.rev !daemons);

    (* A run that exercised nothing must not be able to pass: that is how a job
        goes green over an empty set. *)
    if !ops_run = 0 then begin
      prerr_endline "FAILED: no operation was journalled";
      finish 2
    end;

    (* Settle, then judge. *)
    (* Settle before judging: the checks are about the converged domain, and a
        sample taken mid-upload says nothing. Waiting on the store going quiet
        rather than on a fixed sleep, since how long the load takes to land
        depends on how much of it there was. *)
    let publish_round () =
      List.iter
        (fun home ->
          sh "HOME=%s %s sync --domain %s >/dev/null 2>&1 || true"
            (Filename.quote home) (Filename.quote exe) env.domain)
        [home_a; home_b]
    in
    publish_round ();
    let stable = ref 0 and last = ref (-1) in
    wait_until ~timeout:180. ~what:"the store to stop changing" (fun () ->
        let n = List.length (all_files store) in
        if n = !last && n > 0 then incr stable else stable := 0;
        last := n;
        if !stable >= 3 then true
        else (
          Unix.sleepf 2.;
          false));
    publish_round ();
    Unix.sleepf 3.;

    let ta = tree mnt_a and tb = tree mnt_b in
    (* Says which way each path diverged, because the three possibilities have
       nothing to do with each other: a path only one mount lists is a
       visibility failure, whereas a path both list with different bodies is a
       convergence failure, and they are fixed in different places. Naming the
       first differing path alone left that unanswered. *)
    check "both mounts see the same tree" (fun () ->
        if ta <> tb then begin
          let paths l = List.map fst l in
          let only_a = List.filter (fun p -> not (List.mem p (paths tb))) (paths ta)
          and only_b = List.filter (fun p -> not (List.mem p (paths ta))) (paths tb) in
          let differing =
            List.filter_map
              (fun (p, da) ->
                match List.assoc_opt p tb with
                  | Some db when db <> da -> Some (Printf.sprintf "%s a=%s b=%s" p da db)
                  | _ -> None)
              ta
          in
          let show label = function
            | [] -> ""
            | l -> Printf.sprintf "; %s %s" label (String.concat "," l)
          in
          failf "%d vs %d entries%s%s%s" (List.length ta) (List.length tb)
            (show "only on a:" only_a) (show "only on b:" only_b)
            (show "differing bodies:" differing)
        end);
    check "nothing is listed but unreadable" (fun () ->
        match List.filter (fun (_, d) -> d = "UNREADABLE") ta with
          | (p, _) :: _ -> failf "%s" p
          | [] -> ());
    List.iter
      (fun (path, actual) ->
        match legal_states path with
          | None -> ()
          | Some legal ->
              check (Printf.sprintf "%s holds something that was written" path)
                (fun () ->
                  if not (List.mem (Some actual) legal) then
                    failf "holds %s" actual))
      ta;
    check_store ~store;
    finish (summary ())
  with e ->
    (* Where it came from, not just what it was. An abort is the one outcome
       that reports nothing about the product, so the message has to be enough
       to find the site without a second run to reproduce it. *)
    Printf.printf "stress aborted: %s\n%s%!" (Printexc.to_string e)
      (Printexc.get_backtrace ());
    finish 2
