open Tsync_core

let p fmt = Printf.printf fmt
let records = 50_000

(* Linear adoption takes milliseconds and quadratic takes minutes, so the bound
   leaves room for a CI runner several times slower. *)
let bound = 10.

let kind =
  {
    Dqueue.decode = (fun b -> Some b);
    encode = Fun.id;
    key = (fun b -> Some (List.hd (String.split_on_char '.' b)));
    note = (fun b _ -> b);
    accepts = (fun _ -> true);
  }

(* Under the build directory, on disk: 100k records would take 1.6 GB of a
   tmpfs at one 16 KiB page each. *)
let dir =
  Filename.concat (Sys.getcwd ())
    (Printf.sprintf "tsync-dqs-%d" (Unix.getpid ()))

let id i = Printf.sprintf "%020d-%08d-%d" (1794176842225094 + i) i 1

(* Plain writes: the queue only reads them back, and fsyncing 50k records
   would time the disk. *)
let write_records sub body =
  let d = Filename.concat dir sub in
  Fs.mkdir_p d;
  List.init records (fun i ->
      Out_channel.with_open_bin
        (Filename.concat d (id i))
        (fun oc -> output_string oc (body i));
      id i)

let timed f =
  let t0 = Unix.gettimeofday () in
  f ();
  Unix.gettimeofday () -. t0

let ran = ref []
let ran_m = Mutex.create ()
let outage = Atomic.make false

let run id body ~cancel:_ =
  if Atomic.get outage && body.[0] = 'd' then Fail.raise_ Link "outage";
  Mutex.protect ran_m (fun () -> ran := id :: !ran)

let rec wait_for ?(deadline = Unix.gettimeofday () +. 300.) f =
  if (not (f ())) && Unix.gettimeofday () < deadline then (
    Rt.sleep 0.05;
    wait_for ~deadline f)

let drain q =
  Dqueue.resume q;
  Dqueue.settle ~timeout:300. q;
  let r = List.rev !ran in
  ran := [];
  r

let open_queue sub ~ordered =
  Dqueue.create ~name:sub ~ordered kind
    (Dqueue.Records.open_ (Filename.concat dir sub))

let report q ~start ~rescan =
  p "pending: %d; start under %.0fs: %b; second rescan under %.0fs: %b\n"
    (Dqueue.pending q) bound (start < bound) bound (rescan < bound);
  Printf.eprintf "start %.3fs, rescan %.3fs\n%!" start rescan

let () =
  Fs.rm_rf dir;
  Rt.run_sync (fun () ->
      p "== ordered: %d records adopted from disk run in id order\n" records;
      let ids = write_records "ordered" (Printf.sprintf "k%d") in
      let q = open_queue "ordered" ~ordered:true in
      let start = timed (fun () -> Dqueue.start ~paused:true q run) in
      let rescan = timed (fun () -> Dqueue.rescan q) in
      report q ~start ~rescan;
      let order = drain q in
      p "ran: %d; in id order: %b; pending after: %d\n" (List.length order)
        (order = ids) (Dqueue.pending q);
      p "\n== keyed: %d distinct keys, then %d posts on one key coalesce\n"
        records records;
      ignore (write_records "keyed" (Printf.sprintf "k%d.x"));
      let q = open_queue "keyed" ~ordered:false in
      let start = timed (fun () -> Dqueue.start ~paused:true q run) in
      let rescan = timed (fun () -> Dqueue.rescan q) in
      report q ~start ~rescan;
      let last = ref "" in
      for i = 1 to records do
        last := Dqueue.post q (Printf.sprintf "rep.%d" i)
      done;
      p "pending with the repeated key: %d\n" (Dqueue.pending q);
      let order = drain q in
      p "ran: %d; the repeated key ran once, its newest post: %b\n"
        (List.length order)
        (List.filter (( = ) !last) order = [!last]);
      p "records on disk: %d\n"
        (List.length
           (Dqueue.Records.list
              (Dqueue.Records.open_ (Filename.concat dir "keyed"))));
      p "\n== keyed: %d keys back off in an outage while %d others run\n"
        records records;
      let q = open_queue "outage" ~ordered:false in
      Dqueue.start q run;
      let run_fresh prefix ~left =
        timed (fun () ->
            for i = 1 to records do
              ignore (Dqueue.post q (Printf.sprintf "%s%d.x" prefix i))
            done;
            wait_for (fun () -> Dqueue.pending q = left))
      in
      let alone = run_fresh "b" ~left:0 in
      Atomic.set outage true;
      for i = 1 to records do
        ignore (Dqueue.post q (Printf.sprintf "d%d.x" i))
      done;
      wait_for (fun () -> List.length (Dqueue.retrying q) = records);
      p "backing off: %d\n" (List.length (Dqueue.retrying q));
      let others = run_fresh "u" ~left:records in
      (* Keys in backoff cost a pick nothing, so 3x leaves room for a loaded
         runner. *)
      p "others ran within 3x their time alone: %b; ran: %d\n"
        (others < (3. *. alone) +. 1.)
        (List.length !ran);
      Printf.eprintf "alone %.3fs, during the outage %.3fs\n%!" alone others;
      Atomic.set outage false;
      wait_for (fun () -> Dqueue.idle q);
      p "after the outage, ran: %d; pending: %d\n" (List.length !ran)
        (Dqueue.pending q));
  Test_support.finish dir
