(* An export read straight off a store, against a link that counts, refuses and
   mangles chunk reads: what lands, what a rerun fetches again, and what is left
   in the folder exported to, which is only ever the export. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "export"
let width = 4
let chunk = 8

module Real = (val Fixture.local_store (Filename.concat root "store"))

let chunk_reads = ref 0
let refuse_after = ref max_int
let mangled = ref None
let in_flight = ref 0
let peak_in_flight = ref 0
let peak_open = ref 0
let watch_dir = ref ""

let is_chunk key =
  let key = Stored_key.to_string key in
  let marker = "/chunks/" in
  let n = String.length marker in
  let rec at i =
    i + n <= String.length key && (String.sub key i n = marker || at (i + 1))
  in
  at 0

(* Descriptors this process holds on files under the folder being exported to,
   where the platform has a way to ask. *)
let open_under dir =
  match Sys.readdir "/proc/self/fd" with
    | exception Sys_error _ -> 0
    | fds ->
        Array.fold_left
          (fun n fd ->
            match Unix.readlink (Filename.concat "/proc/self/fd" fd) with
              | target
                when String.length target > String.length dir
                     && String.sub target 0 (String.length dir) = dir ->
                  n + 1
              | _ | (exception Unix.Unix_error _) -> n)
          0 fds

module Link : Backend_lwt.Store = struct
  include Real

  let read key fetch =
    if not (is_chunk key) then fetch ()
    else begin
      incr chunk_reads;
      if !chunk_reads > !refuse_after then
        Lwt.fail
          (Retry.failed ~kind:Retry.Permanent ~op:"get" "the link is down")
      else begin
        incr in_flight;
        peak_in_flight := max !peak_in_flight !in_flight;
        peak_open := max !peak_open (open_under !watch_dir);
        let* () = Lwt_unix.sleep 0.005 in
        let+ body = fetch () in
        decr in_flight;
        body
      end
    end

  let flip body =
    Bigstring.of_string
      (String.map
         (fun c -> Char.chr (Char.code c lxor 0xff))
         (Bigstring.to_string body))

  let spoil key body = if !mangled = Some key then flip body else body
  let get ~key () = read key (fun () -> Lwt.map (spoil key) (Real.get ~key ()))

  let get_opt ~key () =
    read key (fun () -> Lwt.map (Option.map (spoil key)) (Real.get_opt ~key ()))

  let get_many = None
end

module C =
  (val Fixture.conf ~domain:"testdom" ~chunk_size:chunk ~max_downloads:width
         ~store:(module Link : Backend_lwt.Store)
         ~members:
           [Backend.member ~name:"local" (module Link : Backend_lwt.Store)]
         ~root ())

module Lk = Logical_key.Make (C)
module R = Remote_lwt.Make (C)
module E = Export_lwt.Make (C)
module Mfs = Staged_lwt.Manifest.Make (C)

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* Every chunk distinct, or the store holds fewer than the file has. *)
let body ~seed chunks =
  String.concat ""
    (List.init chunks (fun i -> Printf.sprintf "%02d-%05d" seed i))

let upload ?(mtime = 1_700_000_000.) rel contents =
  let src = Filename.concat root "src" in
  write_file src contents;
  R.upload ~key:(Lk.file rel) ~src_path:src ~mtime ~chunk_size:chunk ()

let rec walk dir =
  List.concat_map
    (fun name ->
      let path = Filename.concat dir name in
      if Sys.is_directory path then
        List.map (fun rest -> name ^ "/" ^ rest) (walk path)
      else [name])
    (List.sort compare (Array.to_list (Sys.readdir dir)))

let exports_dir =
  Cache_layout.exports_dir ~cache_root:C.cache_root C.domain_name

let records () =
  try Array.to_list (Sys.readdir exports_dir) with Sys_error _ -> []

let export ?(paths = []) dst =
  chunk_reads := 0;
  peak_in_flight := 0;
  peak_open := 0;
  watch_dir := dst;
  let outcomes = ref [] in
  let+ summary =
    E.run ~dst ~paths
      ~on_event:(function
        | `Finished (rel, outcome) -> outcomes := (rel, outcome) :: !outcomes
        | _ -> ())
      ()
  in
  (summary, List.sort compare !outcomes)

let big = body ~seed:1 10
let small = body ~seed:2 1

let () =
  Lwt_main.run
    (let* (_ : Manifest.t) = upload "big.bin" big in
     let* small_m = upload "docs/small.txt" small in
     let* (_ : Manifest.t) = upload "docs/deep/empty" "" in
     let* aside_m = upload "other/aside.txt" (body ~seed:3 2) in

     case "a fresh export of the whole domain";
     let dst = Filename.concat root "all" in
     let cache = Filename.concat C.cache_root C.domain_name in
     let cached_before = walk cache in
     let* summary, _ = export dst in
     check "every file is exported" (summary.Export.exported = 4);
     check "under its own path, and nothing else is in the folder"
       ~why:(fun () -> String.concat " " (walk dst))
       (walk dst
       = ["big.bin"; "docs/deep/empty"; "docs/small.txt"; "other/aside.txt"]);
     check "with the bytes the domain holds"
       (read_file (Filename.concat dst "big.bin") = big
       && read_file (Filename.concat dst "docs/deep/empty") = "");
     check "and the time it was written"
       ((Unix.stat (Filename.concat dst "big.bin")).Unix.st_mtime
      = 1_700_000_000.);
     check "no record outlives the file it was for" (records () = []);
     check "chunks of one file are fetched side by side, within the budget"
       ~why:(fun () -> string_of_int !peak_in_flight)
       (!peak_in_flight > 1 && !peak_in_flight <= width);
     check "as are the destination files open at once"
       ~why:(fun () -> string_of_int !peak_open)
       (!peak_open <= width);

     case "again";
     let* summary, _ = export dst in
     check "everything is already there" (summary.Export.already_there = 4);
     check "and no chunk is fetched to find that out" (!chunk_reads = 0);

     case "a run cut short";
     let dst = Filename.concat root "cut" in
     refuse_after := 3;
     let* summary, outcomes = export ~paths:["big.bin"] dst in
     refuse_after := max_int;
     check "fails the file it could not finish"
       (summary.Export.failed = 1
       && match outcomes with [("big.bin", `Failed _)] -> true | _ -> false);
     check "leaving it under its name at its full length, and nothing beside it"
       (walk dst = ["big.bin"]
       && (Unix.stat (Filename.concat dst "big.bin")).Unix.st_size
          = String.length big);
     let claimed =
       match records () with
         | [record] ->
             List.length
               (List.filter
                  (fun line -> line <> "")
                  (List.tl
                     (String.split_on_char '\n'
                        (read_file (Filename.concat exports_dir record)))))
         | _ -> -1
     in
     check "with one record in the cache, claiming the three chunks that landed"
       ~why:(fun () -> string_of_int claimed)
       (claimed = 3);
     let* summary, _ = export ~paths:["big.bin"] dst in
     check "the next run fetches the seven it lacks and no more"
       ~why:(fun () -> string_of_int !chunk_reads)
       (summary.Export.exported = 1 && !chunk_reads = 7);
     check "and the file is whole"
       (read_file (Filename.concat dst "big.bin") = big);
     check "its record gone" (records () = []);

     case "a record claiming everything, the run having died before dropping it";
     let dst = Filename.concat root "claimed" in
     let* (_ : Export.summary * _) = export ~paths:["docs/small.txt"] dst in
     let path = Filename.concat dst "small.txt" in
     write_file
       (Cache_layout.export_record_path ~cache_root:C.cache_root
          ~domain_name:C.domain_name path)
       (Export.Record.header
          {
            Export.Record.h1 = Manifest.h1 small_m;
            h2 = Manifest.h2 small_m;
            size = Manifest.size small_m;
            chunk_size = Manifest.chunk_size small_m;
            dst = path;
          }
       ^ Export.Record.claim 0);
     Unix.utimes path 1. 1.;
     let* summary, _ = export ~paths:["docs/small.txt"] dst in
     check "is finished without a fetch"
       (summary.Export.exported = 1 && !chunk_reads = 0);
     check "the time put right and the record dropped"
       ((Unix.stat path).Unix.st_mtime = 1_700_000_000. && records () = []);

     case "what the cache holds after all that";
     check "is what it held before, the exports having put nothing in it"
       ~why:(fun () -> String.concat " " (walk cache))
       (walk cache = cached_before);

     case "content that changed under a run cut short";
     let dst = Filename.concat root "changed" in
     refuse_after := 3;
     let* (_ : Export.summary * _) = export ~paths:["big.bin"] dst in
     refuse_after := max_int;
     let rewritten = body ~seed:9 10 in
     let* (_ : Manifest.t) = upload "big.bin" rewritten in
     let* summary, _ = export ~paths:["big.bin"] dst in
     check "is fetched from its first chunk, nothing of the old spliced in"
       ~why:(fun () -> string_of_int !chunk_reads)
       (summary.Export.exported = 1
       && !chunk_reads = 10
       && read_file (Filename.concat dst "big.bin") = rewritten);

     case "a chunk the store holds wrongly";
     let dst = Filename.concat root "corrupt" in
     let bad_key = Manifest.key aside_m 1 in
     mangled :=
       Some
         (Stored_key.in_space ~prefix:C.chunk_prefix
            (Chunk_layout.relative_path bad_key));
     let* summary, outcomes =
       export ~paths:["other/aside.txt"; "docs/small.txt"] dst
     in
     check "fails the file it belongs to and no other"
       ~why:(fun () ->
         String.concat " "
           (List.map
              (fun (rel, o) ->
                rel ^ "="
                ^
                  match o with
                  | `Failed why -> why
                  | `Exported -> "exported"
                  | _ -> "?")
              outcomes))
       (summary.Export.failed = 1
       && summary.Export.exported = 1
       &&
         match outcomes with
         | [("docs/small.txt", `Exported); ("other/aside.txt", `Failed _)] ->
             true
         | _ -> false);
     mangled := None;
     let* summary, _ = export ~paths:["other/aside.txt"] dst in
     check "and once the store is put right, only that chunk is fetched"
       ~why:(fun () -> string_of_int !chunk_reads)
       (summary.Export.exported = 1 && !chunk_reads = 1);

     case "where things land";
     let dst = Filename.concat root "named" in
     let* (_ : Export.summary * _) =
       export ~paths:["docs"; "big.bin"; "docs/deep/"] dst
     in
     check "a file by its name, a folder under its own"
       ~why:(fun () -> String.concat " " (walk dst))
       (walk dst
       = ["big.bin"; "deep/empty"; "docs/deep/empty"; "docs/small.txt"]);

     case "more files than there are workers";
     let names = List.init 12 (Printf.sprintf "many/%02d.bin") in
     let* () =
       Lwt_list.iteri_s
         (fun i rel ->
           let+ (_ : Manifest.t) = upload rel (body ~seed:(20 + i) 1) in
           ())
         names
     in
     let* summary, _ = export ~paths:["many"] (Filename.concat root "many") in
     check "all arrive" (summary.Export.exported = 12);
     (* Reads are bounded a layer down whatever this does, so it is the files
        held open that say whether the export bounds itself. *)
     check "with no more of them open at once than there are workers"
       ~why:(fun () -> string_of_int !peak_open)
       (!peak_open <= width);

     case "what is refused outright";
     let refused f =
       Lwt.catch
         (fun () ->
           let+ (_ : Export.summary * _) = f () in
           None)
         (function
           | Failure why | Invalid_argument why -> Lwt.return_some why
           | exn -> Lwt.fail exn)
     in
     let* (_ : Manifest.t) = upload "other/small.txt" small in
     let* why =
       refused (fun () ->
           export
             ~paths:["docs/small.txt"; "other/small.txt"]
             (Filename.concat root "clash"))
     in
     check "two files that would land on one name" (why <> None);
     let* why =
       refused (fun () ->
           export ~paths:["nope/x"] (Filename.concat root "none"))
     in
     check "a path the domain does not have"
       (match why with Some why -> String.length why > 6 | None -> false);
     let* why = refused (fun () -> export "relative/dir") in
     check "a destination that depends on where it is run from" (why <> None);

     case "what this machine has not uploaded";
     let staged name =
       {
         Staged_manifest.s_name = name;
         s_size = 0L;
         s_mtime = 0.;
         s_chunk_size = chunk;
         s_slots = [||];
         s_whole = None;
       }
     in
     let* () = Mfs.write (Lk.file "docs/new.txt") (staged "new.txt") in
     let* () = Mfs.write (Lk.file "other/kept.txt") (staged "kept.txt") in
     let* summary, _ =
       export ~paths:["docs"] (Filename.concat root "pending")
     in
     check "is named where it falls under what was asked for, and only there"
       ~why:(fun () -> String.concat " " summary.Export.pending)
       (summary.Export.pending = ["docs/new.txt"]);

     Scratch.cleanup root;
     Lwt.return_unit);
  report ~expected:28 ()
