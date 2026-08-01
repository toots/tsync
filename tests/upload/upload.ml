(* End-to-end multi-chunk upload against a local backend: the real Remote.upload
   path, plus round-trip download and chunk-level dedup. The snapshot suites never
   exceed one 8 MB chunk, so the multi-chunk boundaries are only covered here. *)

open Lwt.Syntax

let chunk_size = 8 * 1024 * 1024

(* Two stored chunks per cache chunk, so the upload/dedup paths run against a
   grouped cache rather than the degenerate one-to-one case. *)
let cache_chunk_size = 2 * chunk_size
let root = Filename.temp_dir "tsync-upload" ""
let backend_root = Filename.concat root "backend"

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
  let backends = [Local_backend.make ~root:backend_root]
  let share_backends = backends
  let cache_root = Filename.concat root "cache"
  let data_dir = Filename.concat root "data"
  let socket_path = Filename.concat root "s.sock"
  let max_uploads = 4
  let max_downloads = 8
  let chunk_size = Some chunk_size
  let cache_chunk_size = Some cache_chunk_size
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module R = Remote.Make (C)
module D = Data.Make (C) (R)

(* New files take the configured size when there is one, else what the primary
   backend recommends (an http-proxy answers with the serving domain's own, so the
   setting lives in one config), else the built-in default. *)

let opinionated n : (module Backend.S) =
  (module struct
    include (val Local_backend.make ~root:backend_root : Backend.S)

    let default_chunk_size ~prefix:_ () = Lwt.return n
    let max_concurrency ~prefix:_ () = Lwt.return_none
  end)

module Unset (B : sig
  val answer : int option
end) =
struct
  include C

  let chunk_size = None
  let backends = [opinionated B.answer]
end

module From_backend = Remote.Make (Unset (struct
  let answer = Some 4096
end))

module No_opinion = Remote.Make (Unset (struct
  let answer = None
end))

(* Distinct per chunk: adding the chunk index shifts each chunk's byte pattern,
   so the three chunks hash to three different keys. *)
let distinct size =
  String.init size (fun i -> Char.chr ((i + (i / chunk_size)) land 0xff))

let write_file path s =
  let oc = open_out_bin path in
  output_string oc s;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let count_chunks () =
  let (module B : Backend.S) = Local_backend.make ~root:backend_root in
  let+ entries = B.list_prefix ~prefix:C.chunk_prefix () in
  List.length
    (List.filter
       (fun (e : Backend.file_entry) ->
         let k = e.key in
         not (String.length k > 0 && k.[String.length k - 1] = '/'))
       entries)

let upload key path = R.upload ~key ~src_path:path ~mtime:0. ~chunk_size ()

let () =
  (* Round-trip through the read path: the manifest is fetched, every chunk is
     pulled into the chunk store and the bytes are written back out. *)
  let round_trip key src expected =
    let dst = src ^ ".out" in
    let* () = D.assemble_to key ~dst_path:dst in
    assert (read_file dst = expected);
    Lwt.return_unit
  in
  Lwt_main.run
    (let size = (2 * chunk_size) + 12345 in

     (* Three distinct chunks (full, full, partial): manifest has 3 entries and
        the bytes round-trip through mmap-hash -> slice -> store -> assemble. *)
     let data = distinct size in
     let src = Filename.concat root "big.bin" in
     write_file src data;
     let* m = upload (C.domain_prefix ^ "big.bin") src in
     assert (Chunk_table.count m.Manifest.chunks = 3);
     assert (m.Manifest.size = Int64.of_int size);
     let* () = round_trip (C.domain_prefix ^ "big.bin") src data in

     (* Fetching the manifest of a file with no local sidecar yields the logical
        size, not the manifest object's own byte size. This is what stat and
        list_dir fall back to for a never-cached file. *)
     let* rm = R.fetch_manifest ~key:(C.domain_prefix ^ "big.bin") () in
     (match rm with
       | Some m -> assert (m.Manifest.size = Int64.of_int size)
       | _ -> assert false);

     (* Dedup: identical content under a new key adds no chunk objects. *)
     let* before = count_chunks () in
     let copy = Filename.concat root "copy.bin" in
     write_file copy data;
     let* _ = upload (C.domain_prefix ^ "copy.bin") copy in
     let* after = count_chunks () in
     assert (after = before);

     (* Three identical chunks: one key, uploaded concurrently in a single batch.
        Exercises the local backend's concurrent same-key write, which must not
        ENOENT on the temp rename, and intra-file dedup to one object. *)
     let dup = String.make (3 * chunk_size) 'Z' in
     let dsrc = Filename.concat root "dup.bin" in
     write_file dsrc dup;
     let* dm = upload (C.domain_prefix ^ "dup.bin") dsrc in
     assert (Chunk_table.count dm.Manifest.chunks = 3);
     let* () = round_trip (C.domain_prefix ^ "dup.bin") dsrc dup in

     (* 0-byte file: one empty chunk, round-trips to empty. *)
     let empty = Filename.concat root "empty.bin" in
     write_file empty "";
     let* em = upload (C.domain_prefix ^ "empty.bin") empty in
     assert (Chunk_table.count em.Manifest.chunks = 1);
     let* () = round_trip (C.domain_prefix ^ "empty.bin") empty "" in

     (* Configured wins outright: nothing is asked of the backend. *)
     let* n = R.chunk_size () in
     assert (n = chunk_size);
     (* Unset: the backend's recommendation, then the built-in default. *)
     let* n = From_backend.chunk_size () in
     assert (n = 4096);
     let* n = No_opinion.chunk_size () in
     assert (n = Conf.default_chunk_size);

     print_endline "ok";
     Lwt.return_unit)
