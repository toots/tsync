(* What a sweep may collect, and what it must leave for whoever is still writing
   it.

   Both sweeps name a leftover by an absence: a temp file nobody has renamed
   yet, and a staged body no manifest names. A write in progress looks like
   both, and neither runs on a quiet machine any more -- they are commands now,
   and a domain may be served while one runs. What separates the two cases is
   pinned here: the owning pid for a temp file, the cutoff for a staged body.
   Get either wrong and the bytes are gone before anything reads them back.

   [init] is what every serving process runs, and it must still touch neither. *)

open Check

let root = Filename.concat (Filename.get_temp_dir_name ()) "tsync-sweep-scope"
let () = ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)))

let conf =
  Fixture.conf ~domain:"sweep" ~root ~verify_writes:false ~chunk_size:64 ()

module C = (val conf : Conf_lwt.S)
module E = Domain_engine.Make (C)
module Mf = Checkout_lwt.Make (C)
module Mfs = Staged_lwt.Manifest.Make (C)

let write path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc

(* Named by [Filename.temp_path], so the recogniser and this agree by
   construction rather than by a spelling copied here. *)
let plant_temp dir ~pid =
  Io_lwt.Fs.mkdir_p_sync dir;
  let path = Filename.concat dir (Printf.sprintf ".tsync-tmp-%d-1.tmp" pid) in
  write path "half-written";
  path

(* A body under a uuid no staged manifest names: what staging looks like between
   creating the body and recording it. [age] backdates it past a cutoff. *)
let plant_staged_body name ~age =
  let dir =
    Cache_layout.staged_whole_dir ~cache_root:C.cache_root C.domain_name
  in
  Io_lwt.Fs.mkdir_p_sync dir;
  let path = Filename.concat dir name in
  write path "bytes a write may be about to use";
  let when_ = Unix.gettimeofday () -. age in
  Unix.utimes path when_ when_;
  path

let mirror_root =
  Cache_layout.manifests_dir ~cache_root:C.cache_root C.domain_name

(* No process has this one: 999999 is above the default pid ceiling on both
   Linux and macOS, so nothing can be occupying it. *)
let dead_pid = 999999

let show what path =
  step "%s: %s" what (if Sys.file_exists path then "present" else "gone")

let () =
  Lwt_main.run
    (let open Lwt.Syntax in
     let* () = E.init () in

     let mine = plant_temp mirror_root ~pid:(Unix.getpid ()) in
     let theirs = plant_temp mirror_root ~pid:dead_pid in
     let fresh = plant_staged_body "0123456789abcdef" ~age:0. in
     let stale = plant_staged_body "fedcba9876543210" ~age:7200. in

     case "a serving process starts";
     let* () = E.init () in
     show "temp file, owner alive" mine;
     show "temp file, owner gone" theirs;
     show "staged body, written just now" fresh;
     show "staged body, two hours old" stale;

     case "the temp sweep runs against a served domain";
     let* swept = Mf.reap_temp_files () in
     step "collected %d file(s), %d byte(s)" swept.Checkout.files
       swept.Checkout.bytes;
     show "temp file, owner alive" mine;
     show "temp file, owner gone" theirs;

     case "the staged sweep runs against a served domain, one hour of grace";
     let cutoff = Unix.gettimeofday () -. 3600. in
     let* swept = Mfs.reclaim_orphan_bodies ~cutoff () in
     step "collected %d body(s), %d byte(s)" swept.Staged_manifest.files
       swept.Staged_manifest.bytes;
     show "staged body, written just now" fresh;
     show "staged body, two hours old" stale;

     Lwt.return_unit);
  report ()
