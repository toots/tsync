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

let attempt path op f =
  let dirty = !fault_in_flight in
  let outcome =
    match f () with
      | () -> if dirty || !fault_in_flight then Interrupted else Acked
      | exception _ -> Failed_op
  in
  record { path; op; outcome; at = Unix.gettimeofday () }

let worker ~mount ~ns ~ops ~seed ~wid ~sizes =
  let rnd = Random.State.make [| seed; Hashtbl.hash ns; wid |] in
  for _ = 1 to ops do
    let name = Printf.sprintf "%s/f%02d" ns (Random.State.int rnd 12) in
    let p = Filename.concat mount name in
    let pick = Random.State.int rnd 100 in
    if pick < 45 then begin
      let data = body rnd (List.nth sizes (Random.State.int rnd (List.length sizes))) in
      with_lock (path_lock name) (fun () ->
          attempt name (Write (digest data)) (fun () ->
              sh "mkdir -p %s" (Filename.quote (Filename.dirname p));
              write_file p data))
    end
    else if pick < 70 then
      with_lock (path_lock name) (fun () ->
          attempt name (Write (if Sys.file_exists p then digest (read_file p) else ""))
            (fun () -> if Sys.file_exists p then ignore (read_file p)))
    else if pick < 85 then begin
      let dst = Printf.sprintf "%s/f%02d" ns (Random.State.int rnd 12) in
      if dst <> name then begin
        let first, second = if name < dst then (name, dst) else (dst, name) in
        with_lock (path_lock first) (fun () ->
            let inner () =
              attempt name Rename_away (fun () ->
                  if Sys.file_exists p then Sys.rename p (Filename.concat mount dst));
              record { path = dst; op = Rename_onto name; outcome = Acked;
                       at = Unix.gettimeofday () }
            in
            if first = second then inner ()
            else with_lock (path_lock second) inner)
      end
    end
    else
      with_lock (path_lock name) (fun () ->
          attempt name Delete (fun () -> if Sys.file_exists p then Sys.remove p));
    Thread.delay (Random.State.float rnd 0.15)
  done

(* {1 The oracle} *)

(* Legal end states for a strict path: what stood after the last acked
   operation, plus what every interrupted one after it would have left. A path
   any rename touched is ambiguous by construction and is not judged. *)
let legal_states path =
  let mine =
    List.filter (fun r -> r.path = path) !journal
    |> List.sort (fun a b -> compare a.at b.at)
  in
  if List.exists (fun r -> match r.op with Rename_away | Rename_onto _ -> true | _ -> false) mine
  then None
  else begin
    let states = ref [] and cur = ref None in
    List.iter
      (fun r ->
        (match r.op with
          | Write "" -> ()                      (* a read, which changes nothing *)
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
         (String.sub p (String.length mount + 1) (String.length p - String.length mount - 1),
          try digest (read_file p) with _ -> "UNREADABLE"))
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
    files
    |> List.filter (fun p -> contains p "/chunks/")
    |> List.map chunk_of
  in
  let manifests = manifests ~env ~store in
  check "the load reached the store" (fun () ->
      if manifests = [] then
        failf "no manifest under %s -- nothing was actually published, so the \
               checks below verified nothing"
          store);
  List.iter
    (fun m ->
      match manifest_chunks m with
        | None -> ()                       (* a folder marker, not a manifest *)
        | Some keys ->
            let missing = List.filter (fun k -> not (List.mem k present)) keys in
            check
              (Printf.sprintf "every chunk of %s is present" (Filename.basename m))
              (fun () ->
                if missing <> [] then
                  failf "%d absent, e.g. %s" (List.length missing)
                    (List.hd missing)))
    manifests

let () =
  let seed =
    match Sys.getenv_opt "TSYNC_STRESS_SEED" with
      | Some s -> int_of_string s
      | None -> Random.int 1_000_000
  in
  let ops = match Sys.getenv_opt "TSYNC_STRESS_OPS" with
    | Some s -> int_of_string s | None -> 60 in
  Printf.printf "seed %d  (replay with TSYNC_STRESS_SEED=%d)\n%!" seed seed;
  (* After the seed is read: where this run stages is incidental, and tying it
     to the seed gave every replay the same directory to collide in. *)
  Random.self_init ();

  let exe = Filename.concat (Sys.getcwd ()) "_build/default/bin/tsync.exe" in
  let root = scratch_root "tss" in
  let store = Filename.concat root "store" in
  let store_home = Filename.concat root "sh" in
  let home_a = Filename.concat root "ha" and home_b = Filename.concat root "hb" in
  let mnt_a = Filename.concat root "mnt-a" and mnt_b = Filename.concat root "mnt-b" in
  List.iter (fun d -> sh "mkdir -p %s" (Filename.quote d))
    [store; store_home; home_a; home_b; mnt_a; mnt_b];

  let pids = ref [] in
  (* Kept on request, and always kept when something failed: a run that found
     something is exactly the one whose logs, store and mounts you want, and
     they are gone the moment this returns. *)
  let keep = Sys.getenv_opt "TSYNC_STRESS_KEEP" <> None in
  let restore ?(failed = false) () =
    List.iter stop_daemon !pids;
    unmount mnt_a; unmount mnt_b;
    Unix.sleepf 1.;
    if keep || failed then
      Printf.printf "left in place for inspection: %s\n%!" root
    else sh "rm -rf %s" (Filename.quote root)
  in
  let finish code = restore (); exit code in

  (try
     Printf.printf "staging in %s\n%!" root;
     write_config ~home:store_home ~name:"stress-store"
       ~domains:[domain_json ~env ~backends:[local_backend ~path:store]
                   ~frontends:[proxy_frontend ~env]];
     pids := spawn_daemon ~exe ~home:store_home ~label:"store" () :: !pids;
     wait_until ~timeout:30. ~what:"the store to listen" (fun () ->
         Sys.command
           (Printf.sprintf "curl -sf -o /dev/null http://127.0.0.1:%d/" env.port)
         = 0);
     List.iter
       (fun (home, label, mount) ->
         write_config ~home ~name:label
           ~domains:[domain_json ~env ~backends:[proxy_backend ~env]
                       ~frontends:[`String "fuse"]];
         (* Without --mount the daemon takes its default under the real HOME,
            leaving these directories empty and every check judging nothing. *)
         pids :=
           spawn_daemon ~args:["--mount"; mount] ~exe ~home ~label () :: !pids)
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

     let sizes = [1024; 64 * 1024; 1_200_000] in
     let threads =
       List.concat_map
         (fun (mount, own) ->
           List.init 3 (fun i ->
               Thread.create (fun () ->
                   worker ~mount ~ns:own ~ops ~seed ~wid:i ~sizes) ())
           @ [ Thread.create (fun () ->
                   worker ~mount ~ns:"shared" ~ops:(ops / 2) ~seed ~wid:99 ~sizes) () ])
         [(mnt_a, "a"); (mnt_b, "b")]
     in
     List.iter Thread.join threads;
     Printf.printf "ops journalled: %d, faults landed: %d\n%!" !ops_run !faults_landed;

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
     check "both mounts see the same tree" (fun () ->
         if ta <> tb then
           failf "%d vs %d entries; first difference %s" (List.length ta)
             (List.length tb)
             (match List.filter (fun e -> not (List.mem e tb)) ta with
               | (p, _) :: _ -> p
               | [] -> (
                   match List.filter (fun e -> not (List.mem e ta)) tb with
                     | (p, _) :: _ -> p
                     | [] -> "?")));
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
     Printf.printf "stress aborted: %s\n%!" (Printexc.to_string e);
     finish 2)
