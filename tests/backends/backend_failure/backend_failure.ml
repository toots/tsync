(* Every backend maps its own errors into {!Retry.kind}, and the shared retry
   loop is the only thing that acts on it. What matters is that a permanent
   failure is reported rather than retried — the queue used to spin on a 403
   forever — and that an unclassified exception still gets retried rather than
   quietly dropping the work. *)

let show name exn =
  Printf.printf "%-28s %s\n" name (Retry.string_of_kind (Backend.classify exn))

let () =
  print_endline "classify";
  show "s3 503 (transient)"
    (Retry.failed ~kind:Retry.Transient ~op:"put" "HTTP 503");
  show "s3 403 (permanent)"
    (Retry.failed ~kind:Retry.Permanent ~op:"put" "forbidden");
  show "not writable" Backend.Not_writable;
  show "backend error" (Backend.Backend_error "missing chunk 3");
  show "unknown exception" (Failure "something new");
  show "unix error" (Unix.Unix_error (Unix.ECONNRESET, "read", ""))

(* Attempts are counted rather than timed: the backoff carries jitter, so only
   how many times the loop ran is reproducible. *)
let count_attempts ~max_attempts exn =
  let attempts = ref 0 in
  let run () =
    Retry_lwt.with_retry ~classify:Backend.classify ~max_attempts ~name:"test"
      ~op:"put" (fun () ->
        incr attempts;
        Lwt.fail exn)
  in
  let outcome =
    try Lwt_main.run (Lwt.bind (run ()) (fun () -> Lwt.return "returned"))
    with e -> Retry.reason e
  in
  (!attempts, outcome)

let attempts name exn =
  let n, outcome = count_attempts ~max_attempts:3 exn in
  Printf.printf "%-28s %d attempt(s), raised %s\n" name n outcome

let () =
  print_newline ();
  print_endline "with_retry (max 3)";
  attempts "transient" (Retry.failed ~kind:Retry.Transient ~op:"put" "HTTP 503");
  attempts "permanent"
    (Retry.failed ~kind:Retry.Permanent ~op:"put" "forbidden");
  attempts "cancelled" Retry.Cancelled;
  attempts "unknown exception" (Failure "something new")
