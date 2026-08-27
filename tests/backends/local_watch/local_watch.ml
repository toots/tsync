(* Whether a local store notices a write without being asked.

   The object a caller waits on is written to a temp name and renamed into
   place, so what is watched is the directory and every event is a hint: the
   assertions below are about when the wait returns, never about what it was
   told. A watch that cannot fire has to cost no more than the sleep it replaced,
   which is the last case here — a directory nothing writes to still returns, and
   returns at the cap. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "local-watch"
let store_dir = Filename.concat root "store"
let cursor = Stored_key.listed "tsync/testdom/cursor"
let watched_dir = Filename.concat store_dir "tsync/testdom"

(* A second store directory nobody writes to. The cap has to be measured
   somewhere no event is outstanding: one write raises several — the temp file
   created, written and renamed — and a drain only takes what had arrived by
   then, so a wait right after one legitimately returns to a leftover. *)
let quiet = Stored_key.listed "tsync/quiet/cursor"

module B = (val Local_backend_lwt.make ~verify_writes:false ~root:store_dir ())

let timed f =
  let started = Unix.gettimeofday () in
  let+ () = f () in
  Unix.gettimeofday () -. started

(* A classification rather than the figure: the cap is seconds and an event
   arrives in milliseconds, so a loaded machine cannot move one into the other,
   where a printed duration would differ on every run. *)
let promptly seconds = seconds < 1.0
let write_cursor body = B.put ~key:cursor ~data:(Bigstring.of_string body) ()

let () =
  Lwt_main.run
    (case "a directory that is not there is not a failure";
     check "no watcher for a path that does not exist"
       (Watch_lwt.open_dir (Filename.concat root "absent") = None);

     let* () = write_cursor "0000000000100-peer" in
     case "a watcher wakes on a rename into the directory";
     let* () =
       match Watch_lwt.open_dir watched_dir with
         | None ->
             check "the store's own directory can be watched" false;
             Lwt.return_unit
         | Some watcher ->
             let* seconds =
               timed (fun () ->
                   (* Bounded here rather than left to [wait], which is
                      deliberately unbounded — capping one is the store's job,
                      not this library's. Without it a watcher that never fires
                      hangs the run instead of failing it. *)
                   let woken =
                     Lwt.catch
                       (fun () ->
                         Lwt_unix.with_timeout 3. (fun () ->
                             Watch_lwt.wait watcher))
                       (fun _ -> Lwt.return_unit)
                   in
                   let* () = Lwt_unix.sleep 0.05 in
                   let* () = write_cursor "0000000000200-peer" in
                   woken)
             in
             check "the wait returned as soon as the rename landed"
               (promptly seconds);
             Watch_lwt.close watcher;
             Lwt.return_unit
     in

     case "the store's own wait returns at once when the object is written";
     let* seconds =
       timed (fun () ->
           let woken = B.watch ~key:cursor ~last_seen:None () in
           let* () = Lwt_unix.sleep 0.05 in
           let* () = write_cursor "0000000000300-peer" in
           woken)
     in
     check "woken by the write rather than by the cap" (promptly seconds);

     case "a watcher that has been drained goes quiet again";
     let* () =
       match Watch_lwt.open_dir watched_dir with
         | None ->
             check "the store's own directory can be watched" false;
             Lwt.return_unit
         | Some watcher ->
             let* () = write_cursor "0000000000400-peer" in
             (* Long enough for every event that write raises, not just the one
                that wakes: the temp file created, written and renamed. *)
             let* () = Lwt_unix.sleep 0.3 in
             (* Returns at once and drains what is queued, which is the state
                the assertion below is about. *)
             let* () =
               Lwt.catch
                 (fun () ->
                   Lwt_unix.with_timeout 1. (fun () -> Watch_lwt.wait watcher))
                 (fun _ -> Lwt.return_unit)
             in
             let* quiet =
               Lwt.catch
                 (fun () ->
                   let* () =
                     Lwt_unix.with_timeout 1. (fun () -> Watch_lwt.wait watcher)
                   in
                   Lwt.return_false)
                 (fun _ -> Lwt.return_true)
             in
             (* A descriptor that stays readable once anything has happened is a
                poller that never sleeps, and every other case here still
                passes while it does. *)
             check "the wait blocks rather than returning to a stale event"
               quiet;
             Watch_lwt.close watcher;
             Lwt.return_unit
     in

     case "and returns at the cap when nothing happens";
     Unix.mkdir (Filename.concat store_dir "tsync/quiet") 0o755;
     let* seconds = timed (fun () -> B.watch ~key:quiet ~last_seen:None ()) in
     check "a directory nothing writes to still returns"
       (not (promptly seconds));
     Lwt.return_unit);
  Scratch.cleanup root
