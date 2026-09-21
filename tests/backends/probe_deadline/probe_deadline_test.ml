(* A backend that never answers must not hold up the report.

   Backend calls carry a retry ladder — eight attempts backing off to 20s — which
   is right for work that has to land eventually and wrong for a health check.
   Worse, a peer that goes away without a FIN never fails at all, so the ladder
   never even starts and the call simply hangs: [tsync status] printed nothing
   while a wedged store sat there. The probe carries its own deadline, and this
   is what proves it — without one, [domain_json] below never returns and the
   bound in [main] is what fails the test. *)

open Lwt.Syntax

let root = "/tmp/tsync-probe-deadline-test"

(* Every call parks forever, so nothing here raises: a store that refuses is
   already covered elsewhere, and what is under test is the answer that never
   comes. *)
module Hung = Doubles.Hung

module C =
  (val Fixture.conf ~domain:"wedgedom" ~client_name:"test-client" ~max_uploads:2
         ~max_downloads:3 ~socket_path:(root ^ "/absent.sock") ~chunk_size:65536
         ~cache_chunk_size:65536
         ~store:
           (Fixture.local_store
              (root ^ "/store")
              (* The store that never answers, declared as the daemon would. *))
         ~members:
           [
             Backend.member ~name:"wedged" ~backend_type:"http-proxy"
               ~config:[("url", "http://wedged.example:8000")]
               (module Hung : Backend_lwt.Store);
           ]
         ~root ()
      : Conf_lwt.S)

module Diag = Diagnostics.Make (C)

let member name j = Yojson.Safe.Util.member name j

(* Generous next to the probe's own deadline: this is here to turn "hangs
   forever" into a failed test, not to measure how long the probe takes. *)
let bound = 120.

let main () =
  let* domain = Lwt_unix.with_timeout bound (fun () -> Diag.domain_json ()) in
  let wedged =
    match member "backends" domain with
      | `List [b] -> b
      | _ -> failwith "expected exactly one backend"
  in
  print_endline "probe of a backend that never answers";
  Printf.printf "  reachable %s\n"
    (Yojson.Safe.to_string (member "reachable" wedged));
  Printf.printf "  error     %s\n"
    (Yojson.Safe.to_string (member "error" wedged));
  (* Said once: a store that did not answer has no journal to describe, and is
     not asked for one at another deadline's cost. *)
  Printf.printf "  journal   %s\n"
    (Yojson.Safe.to_string (member "journal" wedged));
  (* A page redrawn within the window is served what the first report found,
     rather than waiting out the deadline again: the same wedged store, asked
     again straight away, answers at once. *)
  let started = Unix.gettimeofday () in
  let+ again = Lwt_unix.with_timeout bound (fun () -> Diag.domain_json ()) in
  let elapsed = Unix.gettimeofday () -. started in
  print_endline "asked again within the window";
  Printf.printf "  answered at once %b\n" (elapsed < 1.);
  Printf.printf "  same finding    %b\n"
    (member "backends" again = member "backends" domain)

let () = Lwt_main.run (main ())
