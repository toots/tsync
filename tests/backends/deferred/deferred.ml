(* What a deferred target owes, and what it takes to lose it.

   A write returns once the mains have it, so everything a target still needs is
   a job on disk. Those jobs are the subject here: the write records one before
   it returns, a failure that can clear is waited out rather than dropped, one
   that cannot says so, and the process exiting is not what loses them.

   Each case prints what it did, what the target ended up with, and what is still
   owed, so the snapshot states the policy rather than just passing.

   Keys are printed by short label ([c0], [one]): the real ones are hex digests
   that say nothing here. *)

open Lwt.Syntax
open Check

let root = Filename.temp_dir "tsync-deferred" ""
let main_root = Filename.concat root "main"
let log_dir = Filename.concat root "pending"
let chunk_prefix = "tsync/d/chunks/"
let journal_prefix = "tsync/d/journal/"
let cursor_key = "tsync/d/cursor"
let manifest_prefix = "tsync/d/manifests/"
let labels : (string * string) list ref = ref []
let hex n = Printf.sprintf "%016x" n

let chunk n =
  let key =
    chunk_prefix ^ Chunk_layout.relative_path (hex n ^ "-" ^ hex (n + 1))
  in
  labels := (key, Printf.sprintf "c%d" n) :: !labels;
  key

let manifest_key name = manifest_prefix ^ name

let label key =
  match List.assoc_opt key !labels with
    | Some l -> "chunk " ^ l
    | None ->
        if key = cursor_key then "cursor"
        else if String.starts_with ~prefix:journal_prefix key then "journal"
        else if String.starts_with ~prefix:manifest_prefix key then
          "manifest "
          ^ String.sub key
              (String.length manifest_prefix)
              (String.length key - String.length manifest_prefix)
        else key

let manifest ~name chunks =
  let keys = List.map Filename.basename chunks in
  Chunk_table.encode ~name
    ~size:(Int64.of_int (List.length keys * 4))
    ~chunk_size:4 ~mtime:0. ~h1:(hex 0) ~h2:(hex 1) ~symlink:None ~keys

let chunk_keys data =
  match Chunk_table.of_string data with
    | t -> List.init (Chunk_table.count t) (Chunk_table.key t)
    | exception _ -> []

let keys_under dir =
  let rec walk d =
    Sys.readdir d |> Array.to_list
    |> List.concat_map (fun e ->
        let p = Filename.concat d e in
        if Sys.is_directory p then walk p else [p])
  in
  if Sys.file_exists dir then
    List.sort compare
      (List.map
         (fun p ->
           String.sub p
             (String.length dir + 1)
             (String.length p - String.length dir - 1))
         (walk dir))
  else []

let dump_target target_root =
  print_endline "--- target";
  match keys_under target_root with
    | [] -> print_endline "  (empty)"
    | ks -> List.iter (fun k -> Printf.printf "  %s\n" (label k)) ks

(* Jobs still owed, as they sit on disk. *)
let owed name = List.length (keys_under (Filename.concat log_dir name))

(* A store whose first [fails] writes fail in a way that clears on its own — a
   dropped link, a throttling store. Counts what it refused, so the snapshot can
   say the failure really happened rather than just that the job landed. *)
let flaky ~fails ~root : (module Backend.S) * (unit -> int) =
  let left = ref fails in
  let refused = ref 0 in
  let (module Real : Backend.S) =
    Backend.make ~backend_type:"local"
      ~get_field:(function "verifyWrites" -> Some "false" | _ -> Some root)
      ()
  in
  ( (module struct
      include Real

      let put ~key ~data () =
        if !left > 0 then begin
          decr left;
          incr refused;
          Lwt.fail
            (Backend.failed ~kind:Backend.Transient ~op:"put" "link is down")
        end
        else Real.put ~key ~data ()
    end),
    fun () -> !refused )

(* A store nobody can write to, ever: the credential is wrong, the bucket is
   read-only. *)
module Refuses = Doubles.Refuses

(* Reachable only while [up]. *)
let switchable ~up ~root : (module Backend.S) =
  let (module Real : Backend.S) =
    Backend.make ~backend_type:"local"
      ~get_field:(function "verifyWrites" -> Some "false" | _ -> Some root)
      ()
  in
  (module struct
    include Real

    let check op =
      if !up then Lwt.return_unit
      else Lwt.fail (Backend.failed ~kind:Backend.Transient ~op "link is down")

    let put ~key ~data () =
      let* () = check "put" in
      Real.put ~key ~data ()

    let head_opt ~key () =
      let* () = check "head_opt" in
      Real.head_opt ~key ()

    let copy ~src_key ~dst_key () =
      let* () = check "copy" in
      Real.copy ~src_key ~dst_key ()

    let delete ~key () =
      let* () = check "delete" in
      Real.delete ~key ()
  end)

(* {!Deferred.Readable}, as a replica is: reads may reach it, so it carries the
   journal and cursor a peer reading it needs. The composite and the target both
   come back, since the target is what says how far behind it is. *)
let target_for ?resume ~inners ~target ~name () =
  let built = ref None in
  let spec ~source =
    let plain =
      Deferred.make ?resume ~name ~backend:target ~source ~chunk_prefix
        ~chunk_keys ~journal_prefix ~cursor_key ~root:log_dir ()
    in
    let module R = Deferred.Readable ((val plain : Deferred.S)) in
    built := Some (module R : Deferred.S);
    (module R : Deferred.S)
  in
  let composite =
    Domain_store.make
      ~mains:
        (List.mapi
           (fun i backend ->
             { Domain_store.name = Printf.sprintf "main%d" i; backend })
           inners)
      ~targets:[spec] ~archives:[]
  in
  (composite, Option.get !built)

(* Waits for the target to owe nothing, on disk as well as in memory: a job being
   retried is still owed, which is the point. Bounded, so a case that never
   converges fails as a diff rather than a hang. *)
let settled ~name stats =
  let deadline = Unix.gettimeofday () +. 30. in
  let rec go () =
    let s = stats () in
    if s.Deferred.queued = 0 && s.Deferred.in_flight = 0 && owed name = 0 then
      Lwt.return_unit
    else if Unix.gettimeofday () > deadline then begin
      step "gave up waiting on %s" name;
      Lwt.return_unit
    end
    else
      let* () = Lwt_unix.sleep 0.02 in
      go ()
  in
  go ()

let () =
  let main =
    Backend.make ~backend_type:"local"
      ~get_field:(function
        | "verifyWrites" -> Some "false" | _ -> Some main_root)
      ()
  in
  let (module M : Backend.S) = main in
  Lwt_main.run
    (let c0 = chunk 0 and c2 = chunk 2 in
     case "the job is on disk before the write returns, and outlives a failure";
     (* The chunk goes straight to the main, so the only writes this target sees
        come from the manifest job — the first fails, and the job has to survive
        it. *)
     let* () = M.put ~key:c0 ~data:(Chunk.of_string "aaaa") () in
     let t1_root = Filename.concat root "t1" in
     let target1, refused = flaky ~fails:1 ~root:t1_root in
     let l1, (module T1 : Deferred.S) =
       target_for ~inners:[main] ~target:target1 ~name:"flaky" ()
     in
     let (module B1 : Backend.S) = l1 in
     let stats1 = T1.stats in
     let* () =
       B1.put ~key:(manifest_key "one")
         ~data:(Chunk.of_string (manifest ~name:"one" [c0]))
         ()
     in
     step "put manifest one [c0]";
     step "owed the moment the put returned: %d" (owed "flaky");
     let* () = settled ~name:"flaky" stats1 in
     step "owed once caught up: %d (target refused %d, degraded %b)"
       (owed "flaky") (refused ()) (stats1 ()).Deferred.degraded;
     dump_target t1_root;

     case "a failure that cannot clear is dropped, and the target says so";
     let l2, (module T2 : Deferred.S) =
       target_for ~inners:[main] ~target:(module Refuses) ~name:"refuses" ()
     in
     let (module B2 : Backend.S) = l2 in
     let stats2 = T2.stats in
     let* () =
       B2.put ~key:(manifest_key "two")
         ~data:(Chunk.of_string (manifest ~name:"two" [c0]))
         ()
     in
     step "put manifest two [c0]";
     let* () = settled ~name:"refuses" stats2 in
     step "owed: %d (degraded %b — needs tsync mirror)" (owed "refuses")
       (stats2 ()).Deferred.degraded;

     case "a target that was down the whole time a process ran";
     let t3_root = Filename.concat root "t3" in
     let down = ref false in
     let l3, (module T3 : Deferred.S) =
       target_for ~inners:[main]
         ~target:(switchable ~up:down ~root:t3_root)
         ~name:"offline" ()
     in
     let (module B3 : Backend.S) = l3 in
     let* () = B3.put ~key:c2 ~data:(Chunk.of_string "bbbb") () in
     let* () =
       B3.put ~key:(manifest_key "three")
         ~data:(Chunk.of_string (manifest ~name:"three" [c2]))
         ()
     in
     let* () =
       B3.copy ~src_key:(manifest_key "three") ~dst_key:(manifest_key "four") ()
     in
     let* () = B3.delete ~key:(manifest_key "three") () in
     step
       "put chunk c2, put manifest three [c2], copy three -> four, delete three";
     step "owed with the target unreachable: %d" (owed "offline");
     step "on the target so far: %d key(s)" (List.length (keys_under t3_root));

     case "the next daemon start picks up what it left owed";
     (* A second target over the same log, as a restart is: same name, same
        directory, and the link is back. Letting go of the claim is the part of
        a restart this process would otherwise skip, and without it the second
        target reads a log something still alive says is its own. *)
     Deferred.release ~root:log_dir ~name:"offline";
     let up = ref true in
     let l4, (module T4 : Deferred.S) =
       target_for ~resume:true ~inners:[main]
         ~target:(switchable ~up ~root:t3_root)
         ~name:"offline" ()
     in
     let stats4 = T4.stats in
     let* () = settled ~name:"offline" stats4 in
     step "owed once caught up: %d" (owed "offline");
     (* [three] was copied to [four] and then deleted, in that order: a target
        that replayed them out of order would hold neither. *)
     dump_target t3_root;

     case "a replica carries the sync bookkeeping too";
     (* A backfill target skips both; a peer reading a replica needs them. *)
     let t5_root = Filename.concat root "t5" in
     let l5, (module T5 : Deferred.S) =
       target_for ~inners:[main]
         ~target:
           (Backend.make ~backend_type:"local"
              ~get_field:(function
                | "verifyWrites" -> Some "false" | _ -> Some t5_root)
              ())
         ~name:"replica" ()
     in
     let (module B5 : Backend.S) = l5 in
     let stats5 = T5.stats in
     let* () =
       B5.put ~key:(journal_prefix ^ "e1") ~data:(Chunk.of_string "{}") ()
     in
     let* () = B5.put ~key:cursor_key ~data:(Chunk.of_string "e1") () in
     step "put journal entry, put cursor";
     let* () = settled ~name:"replica" stats5 in
     dump_target t5_root;

     case "the mains are what a write waits for";
     let* h = M.head_opt ~key:(manifest_key "one") () in
     step "manifest one on main: %b" (h <> None);
     let* h = M.head_opt ~key:(manifest_key "two") () in
     step "manifest two on main, though its target dropped it: %b" (h <> None);
     Lwt.return_unit)
