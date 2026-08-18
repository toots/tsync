(* What an import tells a caller about its size, against what it actually
   moved.

   [tsync status] reports an import's bytes from three callbacks: the plan says
   how many there are, each entry says how big it is, and the chunks say how
   much of one has landed. Nothing downstream can tell a figure that stopped
   arriving from a run that has nothing to say, so the assertions here are that
   each of the three adds up to the file sizes on disk — a chunk callback lost
   anywhere between {!Remote.upload} and here leaves the per-entry sums at
   zero.

   The chunk size is small enough that a file is several chunks, since a
   single-chunk file would report its whole size in one call and prove
   nothing about the running sum. *)

open Lwt.Syntax
open Check

let root = Filename.temp_dir "tsync-import-progress" ""
let src = Filename.concat root "src"
let main_dir = Filename.concat root "main"
let chunk_size = 64

module Main =
  (val Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some main_dir)
      : Backend.S)

module C : Conf.S = struct
  let versioning = false
  let client_name = "test"
  let domain_name = "testdom"
  let domain_prefix = "tsync/testdom/manifests/"
  let chunk_prefix = "tsync/testdom/chunks/"
  let versions_prefix = "tsync/testdom/versions/"
  let journal_prefix = "tsync/testdom/journal/"
  let cursor_key = "tsync/testdom/cursor"
  let shares_prefix = "tsync/shares/"

  let members =
    [
      Backend.member ~role:"main" ~backend_type:"local" ~local_path:main_dir
        ~name:"main"
        (module Main);
    ]

  let store =
    Domain_store.make
      ~mains:[{ Domain_store.name = "main"; backend = (module Main) }]
      ~targets:[] ~archives:[]

  let cache_root = Filename.concat root "cache"
  let data_dir = Filename.concat root "data"
  let socket_path = ""
  let max_uploads = 1
  let max_chunk_buffers = 2
  let max_downloads = 1
  let chunk_size = Some chunk_size
  let cache_chunk_size = chunk_size
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

module I = Import.Make (C)

let write rel bytes =
  let path = Filename.concat src rel in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.dirname path)));
  let oc = open_out_bin path in
  output_string oc (String.init bytes (fun i -> Char.chr (i mod 251)));
  close_out oc;
  (rel, bytes)

(* Every figure one run reported, so an assertion reads what a caller would
   have shown. *)
type seen = {
  mutable planned_files : int;
  mutable planned_bytes : int64;
  mutable started : (string * int64) list;
  mutable chunked : (string * int64) list;  (** summed per entry *)
  mutable done_ : (string * int64) list;
  mutable skipped : string list;
}

let run () =
  let seen =
    {
      planned_files = 0;
      planned_bytes = 0L;
      started = [];
      chunked = [];
      done_ = [];
      skipped = [];
    }
  in
  let current = ref "" in
  let+ (_ : Import.summary) =
    I.run ~src
      ~on_plan:(fun ~files ~bytes ->
        seen.planned_files <- files;
        seen.planned_bytes <- bytes)
      ~on_start:(fun ~rel ~size ->
        current := rel;
        seen.started <- (rel, size) :: seen.started)
      ~on_progress:(fun ~bytes ->
        let so_far =
          Option.value ~default:0L (List.assoc_opt !current seen.chunked)
        in
        seen.chunked <-
          (!current, Int64.add so_far bytes)
          :: List.remove_assoc !current seen.chunked)
      ~on_file:(fun ~rel status ->
        match status with
          | Import.Imported size -> seen.done_ <- (rel, size) :: seen.done_
          | Import.Skipped_exists -> seen.skipped <- rel :: seen.skipped
          | Import.Skipped_symlink | Import.Failed _ -> ())
      ()
  in
  seen

let () =
  Lwt_main.run
    (let files =
       [
         write "big.bin" (chunk_size * 5);
         write "sub/small.bin" 3;
         write "sub/exact.bin" (chunk_size * 2);
       ]
     in
     let total =
       List.fold_left
         (fun acc (_, n) -> Int64.add acc (Int64.of_int n))
         0L files
     in
     case "what the plan promised";
     let* first = run () in
     check "every file is planned" (first.planned_files = List.length files);
     check
       (Printf.sprintf "and their bytes are what is on disk (%Ld)"
          first.planned_bytes)
       (first.planned_bytes = total);

     case "what each entry said about itself";
     check "an entry is announced at its size"
       ~why:(fun () ->
         String.concat ", "
           (List.map (fun (r, n) -> Printf.sprintf "%s=%Ld" r n) first.started))
       (List.sort compare first.started
       = List.sort compare (List.map (fun (r, n) -> (r, Int64.of_int n)) files)
       );
     check "and finishes at the size it imported"
       (List.sort compare first.done_ = List.sort compare first.started);

     case "what the chunks added up to";
     List.iter
       (fun (rel, n) ->
         let reported =
           Option.value ~default:0L (List.assoc_opt rel first.chunked)
         in
         check
           (Printf.sprintf "%s reported %Ld of its %d bytes" rel reported n)
           (reported = Int64.of_int n))
       files;

     case "a second run over the same tree";
     let* again = run () in
     check "plans the same bytes" (again.planned_bytes = total);
     check "and finds every one of them already in the domain"
       (List.length again.skipped = List.length files && again.done_ = []);

     (* Counted, so a fixture that stopped importing anything fails rather than
        passing quietly. *)
     report ~expected:9 ();
     Lwt.return_unit)
