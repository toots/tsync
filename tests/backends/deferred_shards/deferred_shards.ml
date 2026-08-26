(* What a deferred target asks about the chunks a manifest names.

   Chunk keys are hashed and three characters split a store 4096 ways, so the
   chunks of one manifest land in as many shards as they have members: asking a
   listing per chunk would be worse than asking a HEAD per chunk, and within a
   single job it is. The saving is across jobs — a catch-up run works through
   manifests by the tens of thousands, and every one of them names shards an
   earlier one already had listed.

   So the counts here are taken over a run of manifests, not one, and the second
   half of the run reuses what the first half learned.

   Nothing reads a clock; the counts are the assertion. *)

open Lwt.Syntax

let root = "/tmp/tsync-deferred-shards-test"
let src_dir = root ^ "/src"
let dst_dir = root ^ "/dst"
let log_dir = root ^ "/log"
let chunk_prefix = "tsync/testdom/chunks/"
let manifest_prefix = "tsync/testdom/manifests/"

module Src =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(function
           | "verifyWrites" -> Some "false" | _ -> Some src_dir)
         ()
      : Backend_lwt.Store)

module Real =
  (val Backend_lwt.make ~backend_type:"local"
         ~get_field:(function
           | "verifyWrites" -> Some "false" | _ -> Some dst_dir)
         ()
      : Backend_lwt.Store)

let heads = ref 0
let listings = ref 0
let puts = ref 0

module Dst : Backend_lwt.Store = struct
  include Real

  let head_opt ~key () =
    incr heads;
    Real.head_opt ~key ()

  let list_prefix ?max_keys ~prefix () =
    incr listings;
    Real.list_prefix ?max_keys ~prefix ()

  let put ~key ~data () =
    if Stored_key.is_in ~prefix:chunk_prefix key then incr puts;
    Real.put ~key ~data ()
end

(* A manifest body is just the chunk keys it names, so the test controls exactly
   which shards a job touches. *)
let chunk_keys data = String.split_on_char ' ' (String.trim data)

let target =
  Domain_store_lwt.Deferred.make ~name:"replica"
    ~backend:(module Dst)
    ~source:(module Src)
    ~chunk_prefix ~chunk_keys ~journal_prefix:"tsync/testdom/journal/"
    ~cursor_key:(Stored_key.in_space ~prefix:"tsync/testdom/" "cursor")
    ~excluded:(fun _ -> false)
    ~reads_reach:true ~root:log_dir ()

module T = (val target : Domain_store_lwt.Deferred.S)

(* Two hex characters of shard and one of spread, so [chunks] keys land in a
   known, small number of shards. *)
let chunk_key shard n = Printf.sprintf "%03x%013x-%016x" shard n n

(* A record still on disk is work still owed, which the in-memory count does not
   say: a job is popped before it runs, so the queue reads as empty while its
   last job is still in flight. *)
let owed () =
  let dir = Filename.concat log_dir "replica" in
  let rec walk d =
    Sys.readdir d |> Array.to_list
    |> List.concat_map (fun e ->
        let p = Filename.concat d e in
        if Sys.is_directory p then walk p else [p])
  in
  if Sys.file_exists dir then List.length (walk dir) else 0

let settled () =
  let deadline = Unix.gettimeofday () +. 30. in
  let rec go () =
    let s = T.stats () in
    if s.Deferred.queued = 0 && s.Deferred.in_flight = 0 && owed () = 0 then
      Lwt.return_unit
    else if Unix.gettimeofday () > deadline then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.02 in
      go ()
  in
  go ()

(* One manifest per call, naming [per] chunks drawn from [shards]. *)
let publish ~n ~shards ~per =
  let keys =
    List.init per (fun i ->
        chunk_key (List.nth shards (i mod List.length shards)) ((n * per) + i))
  in
  let* () =
    Lwt_list.iter_s
      (fun k ->
        Src.put
          ~key:
            (Stored_key.in_space ~prefix:chunk_prefix
               (Chunk_layout.relative_path k))
          ~data:(Bigstring.of_string k) ())
      keys
  in
  let body = String.concat " " keys in
  let key =
    Stored_key.in_space ~prefix:manifest_prefix (Printf.sprintf "file%04d" n)
  in
  let* () = Src.put ~key ~data:(Bigstring.of_string body) () in
  T.accept (Deferred.Put { key; data = Bigstring.of_string body })

let report title =
  Printf.printf "=== %s\n" title;
  Printf.printf "  head_opt         %d\n" !heads;
  Printf.printf "  list_prefix      %d\n" !listings;
  Printf.printf "  chunk puts       %d\n" !puts

let () =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" root));
  Lwt_main.run
    (let manifests = 40 and per = 4 in
     let shards = [0x0a1; 0x0b2; 0x0c3; 0x0d4] in
     let* () =
       Lwt_list.iter_s
         (fun n -> publish ~n ~shards ~per)
         (List.init manifests (fun i -> i))
     in
     let* () = settled () in
     report
       (Printf.sprintf "%d manifests naming %d chunks each, over %d shards"
          manifests per (List.length shards));

     (* Everything below is already on the target and already known, so a second
        pass over the same chunks must ask nothing at all. *)
     heads := 0;
     listings := 0;
     puts := 0;
     let* () =
       Lwt_list.iter_s
         (fun n ->
           let keys =
             List.init per (fun i ->
                 chunk_key
                   (List.nth shards (i mod List.length shards))
                   ((n * per) + i))
           in
           let body = String.concat " " keys in
           let key =
             Stored_key.in_space ~prefix:manifest_prefix
               (Printf.sprintf "again%04d" n)
           in
           let* () = Src.put ~key ~data:(Bigstring.of_string body) () in
           T.accept (Deferred.Put { key; data = Bigstring.of_string body }))
         (List.init manifests (fun i -> i))
     in
     let+ () = settled () in
     report "the same chunks again, under new manifest names")
