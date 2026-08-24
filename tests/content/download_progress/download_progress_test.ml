(* What a caller showing a progress bar can see while a file is made local.

   Making a file local is two phases — fetch, then reassemble — and both take
   real time on a large file, so reporting only the first leaves the bar frozen
   through the reassembly, which reads as a hang.

   Chunk sizes here are tiny, so one small file is several chunks across several
   groups: the shape of a large file, in bytes.

   Sampling runs concurrently and yields with [Lwt.pause] rather than sleeps.
   What is asserted is the shape of the samples — never absent once started,
   never decreasing, carried past the end of the fetch — none of which depends
   on how many a given scheduling produces. The count is checked too, so a run
   that observed nothing fails rather than passing vacuously. *)

open Lwt.Syntax
open Check

let chunk_size = 4096

(* Four stored chunks per group, so the file below spans several. *)
let cache_chunk_size = 4 * chunk_size
let root = Scratch.dir "progress"
let backend_root = Filename.concat root "backend"

(* [why] runs only on failure, so a passing run prints what the snapshot
   records. *)

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

  let store =
    Backend.make ~backend_type:"local"
      ~get_field:(fun _ -> Some backend_root)
      ()

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

module Lk = Logical_key.Make (C)
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

(* A gap in the middle means a row was closed and reopened; leading absence only
   means the operation was not observed yet. *)
let shape samples =
  let reported = from_first_report samples in
  let holes =
    List.filteri (fun _ x -> Option.is_none x) reported |> List.length
  in
  let first_hole =
    let rec go i = function
      | [] -> -1
      | None :: _ -> i
      | Some _ :: rest -> go (i + 1) rest
    in
    go 0 reported
  in
  let value = function
    | Some (d, t) -> Printf.sprintf "%d/%d" d t
    | None -> "-"
  in
  Printf.sprintf
    "%d sample(s), %d before the first report, %d reported, %d gap(s)%s, first \
     %s, last %s"
    (List.length samples)
    (List.length samples - List.length reported)
    (List.length (List.filter Option.is_some reported))
    holes
    (if first_hole >= 0 then Printf.sprintf " (first at %d)" first_hole else "")
    (value (match reported with x :: _ -> x | [] -> None))
    (value (match List.rev reported with x :: _ -> x | [] -> None))

let () =
  Lwt_main.run
    (let key = Lk.file @@ "movie.bin" in
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
       ~why:(fun () -> shape samples)
       (List.length (List.filter Option.is_some reported) >= 3);
     check "progress is reported continuously once it starts"
       ~why:(fun () -> shape samples)
       (List.for_all Option.is_some reported);
     check "the file came out whole" (read_file dst = data);

     let seen = List.filter_map Fun.id reported in
     let fetched = List.map fst seen in
     check "progress never goes backwards"
       ~why:(fun () -> shape samples)
       (fst
          (List.fold_left
             (fun (ok, prev) n -> (ok && n >= prev, n))
             (true, 0) fetched));
     (* Not [d = total]: the row is removed when the operation returns, so the
        completed state exists only between the last credit and that teardown
        and whether a sampler lands in it is up to the scheduler. What a bar
        must not do is freeze when the fetch ends, so what is asserted is
        progress past everything the fetch could account for. *)
     check "progress advances into the reassembly"
       ~why:(fun () -> shape samples)
       (match List.rev seen with
         | (d, total) :: _ -> d > total - size
         | [] -> false);
     (* The reassembly is counted too, so the total exceeds what was fetched —
        that is what keeps the bar moving after the last chunk lands. *)
     check "the total covers both phases"
       (match seen with (_, total) :: _ -> total > size | [] -> false);

     let dst2 = Filename.concat root "out2.bin" in
     let* samples = sampling key (fun () -> D.assemble_to key ~dst_path:dst2) in
     let reported = from_first_report samples in
     (* The groups are on disk now and credited in full the moment they are
        found, so a row that stops there is the frozen bar rather than a report
        of one. *)
     check "a cached file still reports its reassembly"
       ~why:(fun () -> shape samples)
       (List.length (List.filter Option.is_some reported) >= 3
       && List.for_all Option.is_some reported
       &&
         match List.rev (List.filter_map Fun.id reported) with
         | (d, total) :: _ -> d > total - size
         | [] -> false);

     let staged_key = Lk.file @@ "staged.bin" in
     let staged_src = Filename.concat root "staged.bin" in
     write_file staged_src data;
     let* () = D.stage_whole staged_key ~src_path:staged_src in
     let dst3 = Filename.concat root "out3.bin" in
     let* samples =
       sampling staged_key (fun () -> D.assemble_to staged_key ~dst_path:dst3)
     in
     let reported = from_first_report samples in
     check "a staged file with nothing to fetch is still reported"
       ~why:(fun () -> shape samples)
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
       ~why:(fun () -> shape samples)
       (List.for_all Option.is_some reported);
     check "both copies came out whole"
       (read_file dst4 = data && read_file dst5 = data);

     Lwt.return_unit);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)))
