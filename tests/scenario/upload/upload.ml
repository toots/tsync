(* End-to-end multi-chunk upload against a local backend: the real Remote.upload
   path, plus round-trip download and chunk-level dedup. The snapshot suites never
   exceed one 8 MB chunk, so the multi-chunk boundaries are only covered here. *)

open Lwt.Syntax

let chunk_size = 8 * 1024 * 1024

(* Two stored chunks per cache chunk, so the upload/dedup paths run against a
   grouped cache rather than the degenerate one-to-one case. *)
let cache_chunk_size = 2 * chunk_size
let root = Scratch.dir "upload"
let backend_root = Filename.concat root "backend"

module C = struct
  let versioning = false
  let client_name = "Test"
  let domain_name = "test"
  let domain_prefix = "tsync/test/manifests/"
  let chunk_prefix = "tsync/test/chunks/"
  let versions_prefix = "tsync/test/versions/"
  let journal_prefix = "tsync/test/journal/"
  let cursor_key = Stored_key.in_space ~prefix:"tsync/test/" "cursor"
  let shares_prefix = "tsync/shares/"

  let store =
    Backend_lwt.make ~backend_type:"local"
      ~get_field:(fun _ -> Some backend_root)
      ()

  let members = [Backend.member ~name:"local" store]
  let cache_root = Filename.concat root "cache"
  let data_dir = Filename.concat root "data"
  let socket_path = Filename.concat root "s.sock"
  let max_uploads = 4
  let max_chunk_buffers = 4
  let max_downloads = 8
  let chunk_size = Some chunk_size
  let cache_chunk_size = Some cache_chunk_size
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false

  include Conf_lwt.Monad
end

module Lk = Logical_key.Make (C)
module R = Remote.Make (C)
module D = Data_lwt.Make (C) (R)

(* New files take the configured size when there is one, else what the primary
   backend recommends (an http-proxy answers with the serving domain's own, so the
   setting lives in one config), else the built-in default. *)

(* Appends to whatever [moving] names as the first chunk is stored, so a source
   changing mid-upload is the store's doing rather than a race with the clock. *)
let moving = ref ""

module Mutating = struct
  include
    (val Backend_lwt.make ~backend_type:"local"
           ~get_field:(fun _ -> Some backend_root)
           ()
        : Backend_lwt.Store)

  let put ~key ~data () =
    if !moving <> "" then begin
      let path = !moving in
      moving := "";
      let oc = open_out_gen [Open_append; Open_binary] 0o644 path in
      output_string oc "!";
      close_out oc
    end;
    put ~key ~data ()
end

module Cm = struct
  include C

  let store = (module Mutating : Backend_lwt.Store)
  let members = [Backend.member ~name:"local" store]
end

module Rm = Remote.Make (Cm)

let opinionated n : (module Backend_lwt.Store) =
  (module struct
    include
      (val Backend_lwt.make ~backend_type:"local"
             ~get_field:(fun _ -> Some backend_root)
             ()
          : Backend_lwt.Store)

    let get_many = None

    let capabilities ~prefix:_ () =
      Lwt.return { Backend.no_caps with chunk_size = n }
  end)

module Unset (B : sig
  val answer : int option
end) =
struct
  include C

  let chunk_size = None
  let store = opinionated B.answer
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
  let (module B : Backend_lwt.Store) =
    Backend_lwt.make ~backend_type:"local"
      ~get_field:(fun _ -> Some backend_root)
      ()
  in
  let+ entries = B.list_prefix ~prefix:C.chunk_prefix () in
  List.length
    (List.filter
       (fun (e : Backend.file_entry) ->
         let k = e.key in
         let k = Stored_key.to_string k in
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
     let* m = upload (Lk.file @@ "big.bin") src in
     assert (Manifest.count m = 3);
     assert (Manifest.size m = Int64.of_int size);
     let* () = round_trip (Lk.file @@ "big.bin") src data in

     (* Fetching the manifest of a file with no local sidecar yields the logical
        size, not the manifest object's own byte size. This is what stat and
        list_dir fall back to for a never-cached file. *)
     let* rm = R.fetch_manifest ~key:(Lk.file "big.bin") () in
     (match rm with
       | Some m -> assert (Manifest.size m = Int64.of_int size)
       | _ -> assert false);

     (* Dedup: identical content under a new key adds no chunk objects. *)
     let* before = count_chunks () in
     let copy = Filename.concat root "copy.bin" in
     write_file copy data;
     let* _ = upload (Lk.file @@ "copy.bin") copy in
     let* after = count_chunks () in
     assert (after = before);

     (* Three identical chunks: one key, uploaded concurrently in a single batch.
        Exercises the local backend's concurrent same-key write, which must not
        ENOENT on the temp rename, and intra-file dedup to one object. *)
     let dup = String.make (3 * chunk_size) 'Z' in
     let dsrc = Filename.concat root "dup.bin" in
     write_file dsrc dup;
     let* dm = upload (Lk.file @@ "dup.bin") dsrc in
     assert (Manifest.count dm = 3);
     let* () = round_trip (Lk.file @@ "dup.bin") dsrc dup in

     (* 0-byte file: one empty chunk, round-trips to empty. *)
     let empty = Filename.concat root "empty.bin" in
     write_file empty "";
     let* em = upload (Lk.file @@ "empty.bin") empty in
     assert (Manifest.count em = 1);
     let* () = round_trip (Lk.file @@ "empty.bin") empty "" in

     (* Configured wins outright: nothing is asked of the backend. *)
     let* n = R.chunk_size () in
     assert (n = chunk_size);
     (* Unset: the backend's recommendation, then the built-in default. *)
     let* n = From_backend.chunk_size () in
     assert (n = 4096);
     let* n = No_opinion.chunk_size () in
     assert (n = Conf.default_chunk_size);

     (* A source that moves under the upload publishes nothing: its chunks would
        otherwise describe a file that never existed. *)
     let moving_src = Filename.concat root "moving.bin" in
     (* Content of its own, or every chunk dedups and no put ever runs. *)
     write_file moving_src
       (String.init size (fun i -> Char.chr (((i * 7) + 3) land 0xff)));
     moving := moving_src;
     let mkey = Lk.file @@ "moving.bin" in
     let* outcome =
       Lwt.catch
         (fun () ->
           let+ (_ : Manifest.t) =
             Rm.upload ~key:mkey ~src_path:moving_src ~mtime:0. ~chunk_size ()
           in
           "published")
         (function
           | Remote.Source_changed _ -> Lwt.return "rejected"
           | exn -> Lwt.fail exn)
     in
     assert (outcome = "rejected");
     let* published = Rm.fetch_manifest ~key:mkey () in
     assert (published = None);

     print_endline "ok";
     Lwt.return_unit)
