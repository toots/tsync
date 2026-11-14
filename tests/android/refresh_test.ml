(* android §3.2, refresh passes: one read of the log for every held folder,
   merged only where it touches, and one pass at a time. *)

open Tsync_android
open Lazy_harness

let folders = List.init 200 (Printf.sprintf "f%03d")

(* Long enough to outlast waiting for a pass to end. *)
let freshness = 4.
let wait_stale () = Thread.delay (freshness +. 0.1)

(* How long a refresh waits for a pass that does not end. *)
let patience = 1.

let timed_refresh () =
  let started = Unix.gettimeofday () in
  let answer = outcome (action "refresh" []) in
  let waited = Unix.gettimeofday () -. started in
  let after =
    if waited < patience then "before the patience"
    else if waited < patience +. 1. then "at the patience"
    else Printf.sprintf "after %.1f s" waited
  in
  answer ^ ", " ^ after

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

(* Each folder's position and pull marker, by modification time. *)
let folder_files () =
  let rec walk dir acc =
    Array.fold_left
      (fun acc name ->
        let path = Filename.concat dir name in
        if name = ".tsync-position" || name = ".tsync-pulled" then
          (path, (Unix.stat path).st_mtime) :: acc
        else if Sys.is_directory path && name <> "peer" then walk path acc
        else acc)
      acc (Sys.readdir dir)
  in
  walk root []

let folders_written before =
  List.filter (fun file -> not (List.mem file before)) (folder_files ())
  |> List.map (fun (path, _) -> Filename.dirname path)
  |> List.sort_uniq String.compare
  |> List.length

let pass label =
  let files = folder_files () in
  let before = Atomic.get entry_reads in
  let notices_before = snd (seen ()) in
  p "  %-34s %s" "refresh" (timed_refresh ());
  p "  %-34s %s"
    (label ^ ", notices when answered")
    (if snd (seen ()) > notices_before then "sent" else "none yet");
  until_quiet ();
  p "  %-34s %d" (label ^ ", log entries read") (Atomic.get entry_reads - before);
  p "  %-34s %d" (label ^ ", folders written") (folders_written files);
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
           refresh_patience = patience;
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

  p "== a peer writes into a folder pulled since";
  wait_stale ();
  ignore (action "list_dir" [s "ref" (ref_of root "f010"); s "pull" "now"]);
  peer_writes "f010/after.txt" "after";
  quiet ();
  Mutex.protect notices_m (fun () -> notices := []);
  pass "pass";

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
  p "  %-34s %s" "refresh" (timed_refresh ());
  p "  %-34s %s" "refresh during it" (timed_refresh ());
  Atomic.set mode `Up;
  until_quiet ();
  p "  %-34s %d" "log entries read" (Atomic.get entry_reads - before);
  show_notices "notices"
