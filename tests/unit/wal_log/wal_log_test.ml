(* A domain's records are one log, however many places name it.

   [Wal.Make] is applied wherever the log is read or written -- the file
   operations, the queue that drains them, the replay, the diagnostics -- and
   every application used to build its own [Records.t] over the same directory.
   Nothing was wrong yet: a record's id comes from its entry key, so the
   per-instance counter that separates two ids minted in the same microsecond
   was never reached. It would have been reached by the first caller to post
   without one. *)

open Check

let root = Scratch.dir "wal-log"
let domain = "testdom"

module Store =
  (val Backend.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

let conf ~domain =
  Fixture.conf ~domain
    ~chunk_size:(8 * 1024 * 1024)
    ~cache_chunk_size:(8 * 1024 * 1024)
    ~store:(module Store : Backend.S)
    ~cache_root:root ~data_dir:root ~root ()

module C = (val conf ~domain : Conf.S)
module W1 = Wal.Make (C)
module W2 = Wal.Make (C)

(* A second domain to show the sharing is per directory rather than global. *)
module D = (val conf ~domain:"otherdom" : Conf.S)
module W3 = Wal.Make (D)

let () =
  case "one domain";
  check "two applications share one record log" (W1.log == W2.log);
  case "two domains";
  check "a second domain gets its own" (not (W1.log == W3.log));
  report ~expected:2 ()
