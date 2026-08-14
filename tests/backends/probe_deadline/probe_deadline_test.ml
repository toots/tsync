(* A backend that never answers must not hold up the report.

   Backend calls carry a retry ladder — eight attempts backing off to 20s — which
   is right for work that has to land eventually and wrong for a health check.
   Worse, a peer that goes away without a FIN never fails at all, so the ladder
   never even starts and the call simply hangs: [tsync stats] printed nothing
   while a wedged store sat there. The probe carries its own deadline, and this
   is what proves it — without one, [domain_json] below never returns and the
   bound in [main] is what fails the test. *)

open Lwt.Syntax

let root = "/tmp/tsync-probe-deadline-test"

(* Every call parks forever, so nothing here raises: a store that refuses is
   already covered elsewhere, and what is under test is the answer that never
   comes. *)
module Hung : Backend.S = struct
  let never () = fst (Lwt.wait ())
  let put ~key:_ ~data:_ () = never ()
  let put_if_absent ~key:_ ~data:_ () = never ()
  let get ~key:_ () = never ()
  let get_opt ~key:_ () = never ()
  let head_opt ~key:_ () = never ()
  let delete ~key:_ () = never ()
  let delete_multi _ = never ()
  let copy ~src_key:_ ~dst_key:_ () = never ()
  let list_prefix ?max_keys:_ ~prefix:_ () = never ()
  let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
end

module C : Conf.S = struct
  let versioning = false
  let client_name = "test-client"
  let domain_name = "wedgedom"
  let domain_prefix = "tsync/wedgedom/manifests/"
  let chunk_prefix = "tsync/wedgedom/chunks/"
  let versions_prefix = "tsync/wedgedom/versions/"
  let journal_prefix = "tsync/wedgedom/journal/"
  let cursor_key = "tsync/wedgedom/cursor"
  let shares_prefix = "tsync/shares/"

  let store =
    Backend.make ~backend_type:"local" ~get_field:(fun _ ->
        Some (root ^ "/store"))

  (* The store that never answers, declared as the daemon would. *)
  let members =
    [
      Backend.member ~name:"wedged" ~backend_type:"http-proxy"
        ~config:[("url", "http://wedged.example:8000")]
        (module Hung);
    ]

  let cache_root = root ^ "/cache"
  let data_dir = root ^ "/data"
  let socket_path = root ^ "/absent.sock"
  let max_uploads = 2
  let max_chunk_buffers = 2
  let max_downloads = 3
  let chunk_size = Some 65536
  let cache_chunk_size = Some 65536
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module Diag = Diagnostics.Make (C)

let member name j = Yojson.Safe.Util.member name j

(* Generous next to the probe's own deadline: this is here to turn "hangs
   forever" into a failed test, not to measure how long the probe takes. *)
let bound = 120.

(* One probe deadline is the whole point. A backend that never answers is
   discovered by the probe, and everything else about it follows — asking a
   second question over the same dead connection buys nothing and spends the
   deadline again. It used to be two, which put a stats call past the timeout
   its own callers allow it.

   The probe's deadline is not exported, deliberately: only a test would want
   it. So this is the midpoint between one and two of them at its current 10s,
   and what it has to separate is "asked once" from "asked twice". Revisit it if
   that value moves. *)
let two_deadlines_from = 15.

let deadlines_spent elapsed =
  if elapsed < two_deadlines_from then "one" else "more than one"

let timed f =
  let started = Unix.gettimeofday () in
  let+ v = f () in
  (v, Unix.gettimeofday () -. started)

let main () =
  let* domain, elapsed =
    timed (fun () ->
        Lwt_unix.with_timeout bound (fun () -> Diag.domain_json ()))
  in
  (* Straight away, so it falls inside the window: what a second menu open, or a
     poll landing next to one, costs. Nothing — the answer is already known, and
     asking a store that just failed to answer would only fail again. *)
  let+ _, again = timed (fun () -> Diag.domain_json ()) in
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
  Printf.printf "  journal   %s\n"
    (Yojson.Safe.to_string (member "error" (member "journal" wedged)));
  Printf.printf "  cost      %s probe deadline\n" (deadlines_spent elapsed);
  Printf.printf "  again     %s\n"
    (if again < 1. then "answered from the last probe"
     else Printf.sprintf "probed again (%.0fs)" again)

let () = Lwt_main.run (main ())
