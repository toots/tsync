(* What a status report costs a daemon whose store holds a real journal, and
   that a report asked again within the window costs it nothing of the sort.

   The figures are printed to stderr for whoever is measuring; only the
   comparison is asserted, since a machine's speed is not the test's. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "status-cost"

module Local =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.concat root "store"))
         ())

(* Every listing is counted: what a report costs a store is how often it is
   asked, and a remote store asked once a second is the whole complaint. *)
let listings = ref 0

module Store : Backend_lwt.Store = struct
  include Local

  let list_prefix ?max_keys ~prefix () =
    incr listings;
    Local.list_prefix ?max_keys ~prefix ()
end

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Store : Backend_lwt.Store)
         ~members:
           [Backend.member ~name:"disk" (module Store : Backend_lwt.Store)]
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module Fs = File_store_lwt.Make (C)
module Diag = Diagnostics.Make (C)

let entries = 3000

let timed f =
  let t0 = Unix.gettimeofday () and c0 = Metrics.cpu_seconds () in
  let+ () = f () in
  (Unix.gettimeofday () -. t0, Metrics.cpu_seconds () -. c0)

let () =
  Lwt_main.run
    (case "a report over a journal of three thousand entries";
     let* () =
       Lwt_list.iter_s
         (fun i ->
           let+ (_ : Journal.Entry_key.t) =
             Fs.write_journal_entry [`Put (Printf.sprintf "f%d" i, 0L)]
           in
           ())
         (List.init entries Fun.id)
     in
     listings := 0;
     let* first_wall, first_cpu =
       timed (fun () ->
           let+ (_ : Yojson.Safe.t) = Diag.domain_json () in
           ())
     in
     let first_listings = !listings in
     let* again_wall, again_cpu =
       timed (fun () ->
           Lwt_list.iter_s
             (fun _ ->
               let+ (_ : Yojson.Safe.t) = Diag.domain_json () in
               ())
             (List.init 10 Fun.id))
     in
     let again_wall = again_wall /. 10. and again_cpu = again_cpu /. 10. in
     Printf.eprintf
       "first report: %.0f ms wall, %.0f ms cpu; within the window: %.1f ms \
        wall, %.1f ms cpu each\n\
        %!"
       (first_wall *. 1000.) (first_cpu *. 1000.) (again_wall *. 1000.)
       (again_cpu *. 1000.);
     step "the first report listed the store %d time(s)" first_listings;
     check "the first report lists the store" (first_listings > 0);
     check "ten more within the window list it not at all"
       (!listings = first_listings) ~why:(fun () ->
         Printf.sprintf "%d listing(s) for eleven reports" !listings);
     ignore (first_wall, first_cpu, again_wall, again_cpu);
     Lwt.return_unit);
  report ~expected:2 ()
