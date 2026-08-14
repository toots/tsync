(* How many files a whole-file fetch has open at once.

   A file is asked for all groups at once and each fetch opens its destination
   before waiting for a download slot, so unbounded the descriptors held scale
   with the file rather than the transfer: 247 open files inside 200ms on a 250 MB
   file at a 1 MiB group size, against a 256 limit. The download pool was never
   exceeded — the rest were open files waiting for a turn.

   So what is measured is descriptors, not parallelism. The fetch stub blocks
   until released, holding every started fetch in its destination-open state. *)

open Lwt.Syntax

let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

let root = Filename.temp_dir "tsync-fanout" ""
let csize = 64
let slots = 4

(* Nothing here reaches a store: the fetch function is supplied directly. A
   backend that raises makes that explicit rather than quietly succeeding. *)
let unused_store : (module Backend.S) =
  (module struct
    let fail () = Lwt.fail (Backend.Backend_error "no backend in this test")
    let put ~key:_ ~data:_ () = fail ()
    let put_if_absent ~key:_ ~data:_ () = fail ()
    let get ~key:_ () = fail ()
    let get_opt ~key:_ () = fail ()
    let head_opt ~key:_ () = fail ()
    let delete ~key:_ () = fail ()
    let delete_multi _ = fail ()
    let copy ~src_key:_ ~dst_key:_ () = fail ()
    let list_prefix ?max_keys:_ ~prefix:_ () = fail ()
    let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported
    let capabilities ~prefix:_ () = Lwt.return Backend.no_caps
  end)

module C : Conf.S = struct
  let versioning = false
  let client_name = "Test"
  let domain_name = "test"
  let domain_prefix = "tsync/test/manifests/"
  let chunk_prefix = "tsync/test/chunks/"
  let versions_prefix = "tsync/test/versions/"
  let journal_prefix = "tsync/test/journal/"
  let cursor_key = "tsync/test/cursor"
  let shares_prefix = "tsync/shares/"
  let store = unused_store
  let members = []
  let cache_root = Filename.concat root "cache"
  let data_dir = Filename.concat root "data"
  let socket_path = Filename.concat root "s.sock"
  let max_uploads = 2
  let max_chunk_buffers = 2
  let max_downloads = slots
  let chunk_size = Some csize
  let cache_chunk_size = Some csize
  let max_cache = None
  let symlink_policy = `Keep
  let read_only = false
end

(* Every fetch parks here, so each started one holds whatever it opened. *)
let gate, release = Lwt.wait ()
let started = ref 0

module F = struct
  let get_chunk ~chunk_key =
    incr started;
    let+ () = gate in
    String.make csize (Char.chr (Hashtbl.hash chunk_key land 0x7f))
end

module Cc = Chunk_cache.Make (C) (F)

(* Counted through lsof rather than inferred: the descriptor is the point, not
   the promise. *)
let open_cache_files () =
  let ic =
    Unix.open_process_in
      (Printf.sprintf "lsof -F n -p %d 2>/dev/null | grep -c '^n%s' || true"
         (Unix.getpid ())
         ( Filename.quote C.cache_root |> fun s ->
           String.sub s 1 (String.length s - 2) ))
  in
  let n = try int_of_string (String.trim (input_line ic)) with _ -> 0 in
  ignore (Unix.close_process_in ic);
  n

(* One group per stored chunk, what a domain gets when its cache chunk size
   equals its chunk size — the shape that fans out most. *)
let group_of i =
  let key = Printf.sprintf "%016x-%016x" i (i * 7 land 0xffffffff) in
  Chunk_group.of_table
    ~table:
      (Chunk_table.of_string
         (Chunk_table.encode ~name:"f" ~size:(Int64.of_int csize)
            ~chunk_size:csize ~mtime:0. ~h1:(String.make 16 '0')
            ~h2:(String.make 16 '0') ~symlink:None ~keys:[key]))
    ~per:1 0

let () =
  Lwt_main.run
    (let groups = List.filter_map group_of (List.init 200 (fun i -> i)) in
     check "the fixture really is many groups" (List.length groups = 200);

     (* Ask for the whole file at once, the way a materialization does. *)
     let all = Lwt_list.iter_p (fun group -> Cc.ensure ~group ()) groups in

     (* Real filesystem work happens on the blocking pool, so this waits rather
        than merely yielding. *)
     let rec settle n =
       if n = 0 then Lwt.return_unit
       else
         let* () = Lwt_unix.sleep 0.02 in
         settle (n - 1)
     in
     let* () = settle 25 in

     let open_files = open_cache_files () in
     Printf.printf
       "  %d groups asked for, %d fetches started, %d files open\n%!"
       (List.length groups) !started open_files;

     (* The bound is on fetches in flight, so descriptors cannot scale with the
        file. Slack for the temp file of a fetch mid-rename. *)
     check "open files do not scale with the file" (open_files <= slots + 4);
     check "no more fetches start than there are slots" (!started <= slots);
     check "but the transfer is not serialised either" (!started > 1);

     Lwt.wakeup_later release ();
     let+ () = all in
     check "every group still arrives" true);
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)));
  exit (if !failures = 0 then 0 else 1)
