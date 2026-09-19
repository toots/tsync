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

(* The same loop told whose link it is climbing against: it says how each
   attempt went and climbs regardless, whether to wait for it being up to
   whoever has another member to ask. *)
let asked_of health ~fails exn =
  let attempts = ref 0 in
  let run () =
    Retry_lwt.with_retry ~health ~max_attempts:3 ~classify:Backend.classify
      ~name:"test" ~op:"get" (fun () ->
        incr attempts;
        if !attempts <= fails then Lwt.fail exn else Lwt.return_unit)
  in
  let outcome =
    try Lwt_main.run (Lwt.bind (run ()) (fun () -> Lwt.return "answered"))
    with e -> "raised " ^ Retry.reason e
  in
  Printf.sprintf "%d attempt(s), %s, member %s" !attempts outcome
    (if Health.is_held health then "held" else "up")

let () =
  Health.trip_span := 0.;
  let transient = Retry.failed ~kind:Retry.Transient ~op:"get" "HTTP 502"
  and permanent = Retry.failed ~kind:Retry.Permanent ~op:"get" "not found" in
  let row name said = Printf.printf "%-28s %s\n" name said in
  print_newline ();
  print_endline "with_retry (max 3), told which member it is asking";
  let member = Health.create () in
  row "a link that is gone" (asked_of member ~fails:max_int transient);
  row "the next request of it" (asked_of member ~fails:max_int transient);
  row "one lost, then answered" (asked_of (Health.create ()) ~fails:1 transient);
  row "an answer that is a no"
    (asked_of (Health.create ()) ~fails:max_int permanent);
  let member = Health.create () in
  ignore (asked_of member ~fails:max_int transient);
  row "answered while held" (asked_of member ~fails:0 transient);
  row "a store with no link" (asked_of Health.always_up ~fails:2 transient)

(* Called back by a deadline while its first attempt is still out. The wait is
   for a second attempt to have been made had there been one, and what is
   asserted is that there was not. *)
let () =
  let attempts = ref 0 and member = Health.create () in
  let outcome =
    Lwt_main.run
      (Lwt.bind
         (Lwt.catch
            (fun () ->
              Lwt_unix.with_timeout 0.05 (fun () ->
                  Retry_lwt.with_retry ~health:member ~classify:Backend.classify
                    ~name:"test" ~op:"get" (fun () ->
                      incr attempts;
                      fst (Lwt.task ()))))
            (fun exn -> Lwt.return (Printexc.to_string exn)))
         (fun said -> Lwt.map (fun () -> said) (Lwt_unix.sleep 1.2)))
  in
  print_newline ();
  print_endline "with_retry, called back by whoever was waiting";
  Printf.printf "%-28s %d attempt(s), raised %s, member %s\n" "a deadline"
    !attempts outcome
    (if Health.is_down member then "down" else "not held against")
