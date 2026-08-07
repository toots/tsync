(* What a caller showing a progress bar can see while a file is made local.

   Making a file local is two phases — fetch, then reassemble — and both take
   real time on a large file, so reporting only the first leaves the bar frozen
   through the reassembly, which reads as a hang.

   Chunk sizes here are tiny, so one small file is several chunks across several
   groups: the shape of a large file, in bytes.

   Sampling runs concurrently and yields with [Lwt.pause] rather than sleeps.
   What is asserted is the shape of the samples — never absent once started,
   never decreasing, ends complete — which does not depend on how many a given
   scheduling produces. The count is checked too, so a run that observed nothing
   fails rather than passing vacuously. *)

open Lwt.Syntax

let chunk_size = 4096

(* Four stored chunks per group, so the file below spans several. *)
let cache_chunk_size = 4 * chunk_size
let root = Filename.temp_dir "tsync-progress" ""
let backend_root = Filename.concat root "backend"
let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

module C = struct
  let versioning = false
  let client_name = "Test"
  let domain_name = "test"
  let domain_prefix = "tsync/test/manifests/"
  let chunk_prefix = "tsync/test/chunks/"
  let versions_prefix = "tsync/test/versions/"
  let journal_prefix = "tsync/test/journal/"
  let cursor_key = "tsync/test/cursor"
  let shares_prefix = "tsync/shares/"
  let store = Local_backend.make ~root:backend_root
  let members = [Backend.member ~name:"local" store]
  let cache_root = Filename.concat root "cache"
  let data_dir = Filename.concat root "data"
  let socket_path = Filename.concat root "s.sock"
  let max_uploads = 4
  let max_chunk_buffers = 4

  (* More than the chunks in flight, so the download pool never holds the fetch
     up. *)
  let max_downloads = 16
  let chunk_size = Some chunk_size
  let cache_chunk_size = Some cache_chunk_size
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module R = Remote.Make (C)
module D = Data.Make (C) (R)

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(* Distinct bytes throughout, so a misplaced range shows as wrong content rather
   than bytes that happen to match. *)
let distinct n = String.init n (fun i -> Char.chr (i * 7 mod 251))

(* Yields between samples so the two interleave on the one Lwt loop. *)
let sampling key job =
  let samples = ref [] in
  let running = ref true in
  let rec sample () =
    if not !running then Lwt.return_unit
    else (
      samples := D.download_progress key :: !samples;
      let* () = Lwt.pause () in
      sample ())
  in
  let work () =
    Lwt.finalize job (fun () ->
        running := false;
        Lwt.return_unit)
  in
  let+ (), () = Lwt.both (work ()) (sample ()) in
  List.rev !samples

(* A sampler can look before the operation opens its row, and that leading
   absence is not a gap. *)
let from_first_report samples =
  let rec drop = function None :: rest -> drop rest | rest -> rest in
  drop samples

let () =
  Lwt_main.run
    (let key = C.domain_prefix ^ "movie.bin" in
     let size = 40 * chunk_size in
     let data = distinct size in
     let src = Filename.concat root "movie.bin" in
     write_file src data;
     let* (_ : Manifest.t) =
       R.upload ~key ~src_path:src ~mtime:0. ~chunk_size ()
     in

     let* () = D.forget_chunks key in
     let dst = Filename.concat root "out.bin" in
     let* samples = sampling key (fun () -> D.assemble_to key ~dst_path:dst) in
     let reported = from_first_report samples in

     check "the operation was observed while it ran"
       (List.length (List.filter Option.is_some reported) >= 3);
     check "progress is reported continuously once it starts"
       (List.for_all Option.is_some reported);
     check "the file came out whole" (read_file dst = data);

     let seen = List.filter_map Fun.id reported in
     let fetched = List.map fst seen in
     check "progress never goes backwards"
       (fst
          (List.fold_left
             (fun (ok, prev) n -> (ok && n >= prev, n))
             (true, 0) fetched));
     check "progress reaches the end"
       (match List.rev seen with (d, total) :: _ -> d = total | [] -> false);
     (* The reassembly is counted too, so the total exceeds what was fetched —
        that is what keeps the bar moving after the last chunk lands. *)
     check "the total covers both phases"
       (match seen with (_, total) :: _ -> total > size | [] -> false);

     let dst2 = Filename.concat root "out2.bin" in
     let* samples = sampling key (fun () -> D.assemble_to key ~dst_path:dst2) in
     let reported = from_first_report samples in
     check "a cached file still reports its reassembly"
       (List.length (List.filter Option.is_some reported) >= 3
       && List.for_all Option.is_some reported);

     let staged_key = C.domain_prefix ^ "staged.bin" in
     let staged_src = Filename.concat root "staged.bin" in
     write_file staged_src data;
     let* () = D.stage_whole staged_key ~src_path:staged_src in
     let dst3 = Filename.concat root "out3.bin" in
     let* samples =
       sampling staged_key (fun () -> D.assemble_to staged_key ~dst_path:dst3)
     in
     let reported = from_first_report samples in
     check "a staged file with nothing to fetch is still reported"
       (List.length (List.filter Option.is_some reported) >= 3
       && List.for_all Option.is_some reported);
     check "the staged file came out whole" (read_file dst3 = data);

     let* () = D.forget_chunks key in
     let dst4 = Filename.concat root "out4.bin" in
     let dst5 = Filename.concat root "out5.bin" in
     let* samples =
       sampling key (fun () ->
           let+ (), () =
             Lwt.both
               (D.assemble_to key ~dst_path:dst4)
               (D.assemble_to key ~dst_path:dst5)
           in
           ())
     in
     let reported = from_first_report samples in
     (* Whichever finishes first must not take the row away from the other. *)
     check "overlapping materializations keep one shared row"
       (List.for_all Option.is_some reported);
     check "both copies came out whole"
       (read_file dst4 = data && read_file dst5 = data);

     Lwt.return_unit);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)));
  exit (if !failures = 0 then 0 else 1)
