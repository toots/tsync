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
    Backend.make ~backend_type:"local"
      ~get_field:(fun _ -> Some (root ^ "/store"))
      ()

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

let main () =
  let+ domain = Lwt_unix.with_timeout bound (fun () -> Diag.domain_json ()) in
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
    (Yojson.Safe.to_string (member "error" (member "journal" wedged)))

let () = Lwt_main.run (main ())
