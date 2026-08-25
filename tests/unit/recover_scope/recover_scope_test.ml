(* What a process may collect when it starts, and what only the machine may.

   Two sweeps name a leftover by an absence: a temp file nobody has renamed yet,
   and a staged body no manifest names. A write in progress looks like both, so
   a domain served by two frontends has one collecting what the other is in the
   middle of writing -- silently, since the bytes are gone before anything reads
   them back.

   Hence the split pinned here: [init] is what every serving process runs and
   must touch neither, [recover] is what the launcher runs before it forks
   anything and must take both. *)

open Check

let root = Filename.concat (Filename.get_temp_dir_name ()) "tsync-recover-scope"
let () = ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)))

let conf =
  Fixture.conf ~domain:"recov" ~root ~verify_writes:false ~chunk_size:64 ()

module C = (val conf : Conf.S)
module E = Domain_engine.Make (C)

(* Named by [Filename.temp_path], so the recogniser and this agree by
   construction rather than by a spelling copied here. A foreign pid, because
   that is the case that matters: the sweep cannot tell it from a live one. *)
let plant_temp dir =
  Io_lwt.Fs.mkdir_p_sync dir;
  let path = Filename.concat dir ".tsync-tmp-999999-1.tmp" in
  let oc = open_out path in
  output_string oc "half-written";
  close_out oc;
  path

(* A body under a uuid no staged manifest names: what staging looks like between
   creating the body and recording it. *)
let plant_staged_body () =
  let dir =
    Cache_layout.staged_whole_dir ~cache_root:C.cache_root C.domain_name
  in
  Io_lwt.Fs.mkdir_p_sync dir;
  let path = Filename.concat dir "0123456789abcdef" in
  let oc = open_out path in
  output_string oc "bytes a write is about to use";
  close_out oc;
  path

let mirror_root =
  Cache_layout.manifests_dir ~cache_root:C.cache_root C.domain_name

let () =
  Lwt_main.run
    (let open Lwt.Syntax in
     let* () = E.init () in

     case "a serving process starts";
     let temp = plant_temp mirror_root in
     let staged = plant_staged_body () in
     let* () = E.init () in
     check "the temp file another process is writing survives"
       (Sys.file_exists temp);
     check "the staged body another process is about to use survives"
       (Sys.file_exists staged);

     case "the machine starts";
     let* () = E.recover () in
     check "the leftover temp file is collected" (not (Sys.file_exists temp));
     check "the orphaned staged body is collected"
       (not (Sys.file_exists staged));

     Lwt.return_unit);
  report ~expected:4 ()
