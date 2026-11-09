(* android §3.2, refresh passes: one read of the log for every held folder,
   merged only where it touches, and one pass at a time. *)

open Tsync_android
open Lazy_harness

let folders = List.init 200 (Printf.sprintf "f%03d")

(* Long enough to outlast waiting for a pass to end. *)
let freshness = 4.
let wait_stale () = Thread.delay (freshness +. 0.1)

let seen () =
  ( Atomic.get entry_reads,
    Mutex.protect notices_m (fun () -> List.length !notices) )

(* Half a second with no log read and no notice. *)
let quiet () =
  let deadline = Unix.gettimeofday () +. 30. in
  let rec settle last =
    Thread.delay 0.5;
    let now = seen () in
    if now <> last && Unix.gettimeofday () < deadline then settle now
  in
  settle (seen ())

(* A pass's end is not visible to a host: it is waited for as its first
   notice, then quiet. *)
let until_quiet () =
  let deadline = Unix.gettimeofday () +. 30. in
  while snd (seen ()) = 0 && Unix.gettimeofday () < deadline do
    Thread.delay 0.05
  done;
  quiet ()

let op j = Printf.sprintf "%s %s" (text j "op") (text j "name")

let pass label =
  let before = Atomic.get entry_reads in
  p "  %-34s %s" "refresh" (outcome (action "refresh" []));
  until_quiet ();
  p "  %-34s %d" (label ^ ", log entries read") (Atomic.get entry_reads - before);
  show_notices (label ^ ", notices")

let () =
  setup ();
  peer_does (fun (module E) ->
      List.iter (fun f -> E.mkdir f ~exclusive:true) folders);
  p "  %-34s %S" "boot"
    (Android_host.boot
       ~pull_params:
         {
           pull_freshness = freshness;
           view_max_age = 3600.;
           pull_patience = 30.;
           pull_page = 256;
         }
       "");
  let root = action "list_dir" [s "ref" "root"] in
  List.iter
    (fun f -> ignore (action "list_dir" [s "ref" (ref_of root f)]))
    folders;
  p "  %-34s %d" "held folders" (List.length folders + 1);
  let anchor = text (action "cursor" []) "cursor" in
  show_notices "notices of the first pulls";

  p "== a peer writes into three of them";
  List.iter (fun f -> peer_writes (f ^ "/new.txt") f) ["f007"; "f100"; "f199"];
  wait_stale ();
  pass "pass";
  (match field (action "changes_since" [s "arg" anchor]) "ops" with
    | Some (`List ops) ->
        p "  %-34s [%s]" "changes" (String.concat ", " (List.map op ops))
    | _ -> p "  %-34s none" "changes");

  p "== at once again: every folder is fresh";
  let before = Atomic.get entry_reads in
  p "  %-34s %s" "refresh" (outcome (action "refresh" []));
  Thread.delay 0.5;
  p "  %-34s %d" "log entries read" (Atomic.get entry_reads - before);

  p "== two refreshes while the store pends";
  quiet ();
  Mutex.protect notices_m (fun () -> notices := []);
  peer_writes "f050/late.txt" "late";
  wait_stale ();
  Atomic.set mode `Hung;
  let before = Atomic.get entry_reads in
  p "  %-34s %s" "refresh" (outcome (action "refresh" []));
  p "  %-34s %s" "refresh during it" (outcome (action "refresh" []));
  Atomic.set mode `Up;
  until_quiet ();
  p "  %-34s %d" "log entries read" (Atomic.get entry_reads - before);
  show_notices "notices"
