(* Role composition, and how far a read is allowed to look.

   A write goes to the mains alone and waits for them; a replica is filled behind
   it by its lane, which is {!Lane_backend}'s business, not this one's. Mains and
   replicas hold the same content, so the first reachable one's "not found" ends
   the read. Read-only archives hold different content, so they answer both a
   miss and an unreachable source of truth, and are never written. A miss is
   reported only when every backend that could hold the key was asked: "could not
   look" must not reach a caller as "not there". *)

open Lwt.Syntax

let root = Filename.temp_dir "tsync-fallback" ""
let main_root = Filename.concat root "main"
let replica_root = Filename.concat root "replica"
let archive_root = Filename.concat root "archive"
let k name = "tsync/d/manifests/" ^ name

module Down : Backend.S = struct
  let fail () = Lwt.fail (Backend.Backend_error "down")
  let put ~key:_ ~data:_ () = fail ()
  let get ~key:_ () = fail ()
  let get_opt ~key:_ () = fail ()
  let head_opt ~key:_ () = fail ()
  let delete ~key:_ () = fail ()
  let delete_multi _ = fail ()
  let copy ~src_key:_ ~dst_key:_ () = fail ()
  let list_prefix ?max_keys:_ ~prefix:_ () = fail ()
  let share_url ~prefix:_ () = Lwt.return_none
  let default_chunk_size ~prefix:_ () = Lwt.return_none
  let max_concurrency ~prefix:_ () = Lwt.return_none
end

let sub name backend = { Fallback_backend.name; backend }
let case name = Printf.printf "\n=== %s\n" name
let step fmt = Printf.printf ("  " ^^ fmt ^^ "\n")

(* One reporting shape for every read: which of the three outcomes a caller gets
   is the subject of this suite. *)
let outcome to_string p =
  Lwt.catch
    (fun () ->
      let+ v = p () in
      match v with Some v -> to_string v | None -> "none")
    (fun exn ->
      Lwt.return
        ("error: "
        ^
          match exn with
          | Backend.Backend_error m -> m
          | e -> Printexc.to_string e))

let get (module B : Backend.S) key =
  outcome (Printf.sprintf "%S") (fun () -> B.get_opt ~key ())

let head (module B : Backend.S) key =
  outcome
    (fun (e : Backend.file_entry) -> Printf.sprintf "%d bytes" e.size)
    (fun () -> B.head_opt ~key ())

let listing (module B : Backend.S) prefix =
  outcome
    (fun l ->
      match List.map (fun (e : Backend.file_entry) -> e.key) l with
        | [] -> "(empty)"
        | ks -> String.concat " " (List.sort compare ks))
    (fun () ->
      let+ l = B.list_prefix ~prefix () in
      Some l)

let holds root key = Sys.file_exists (Filename.concat root key)

let () =
  let main = Local_backend.make ~root:main_root in
  let replica = Local_backend.make ~root:replica_root in
  let archive = Local_backend.make ~root:archive_root in
  let (module Rep : Backend.S) = replica in
  let (module Arc : Backend.S) = archive in
  Lwt_main.run
    (* Content each store has that the others do not. *)
    (let* () = Rep.put ~key:(k "on-replica") ~data:"from-replica" () in
     let* () = Arc.put ~key:(k "on-archive") ~data:"from-archive" () in

     case "one main, nothing behind it";
     let solo =
       Fallback_backend.make ~sync:[sub "main" main] ~deferred:[] ~fallbacks:[]
     in
     let (module Solo : Backend.S) = solo in
     let* () = Solo.put ~key:(k "on-main") ~data:"from-main" () in
     step "put on-main";
     let* r = get solo (k "on-main") in
     step "get on-main = %s" r;
     let* r = get solo (k "nowhere") in
     step "get nowhere = %s" r;

     case "the only main is unreachable";
     (* Reporting a miss here would tell a caller the file is gone. *)
     let dead =
       Fallback_backend.make
         ~sync:[sub "main" (module Down)]
         ~deferred:[] ~fallbacks:[]
     in
     let* r = get dead (k "nowhere") in
     step "get nowhere = %s" r;
     let* r = head dead (k "nowhere") in
     step "head nowhere = %s" r;

     case "main + replica: same content, so a miss is authoritative";
     let with_rep =
       Fallback_backend.make
         ~sync:[sub "main" main]
         ~deferred:[sub "replica" replica]
         ~fallbacks:[]
     in
     let (module WithRep : Backend.S) = with_rep in
     (* The write waits for the main and nothing else: the replica is filled off
        this path. *)
     let* () = WithRep.put ~key:(k "both") ~data:"both" () in
     step "put both -> on main: %b, on replica: %b"
       (holds main_root (k "both"))
       (holds replica_root (k "both"));
     (* The main is reachable and says no, so the replica is not consulted even
        though it happens to hold this one. *)
     let* r = get with_rep (k "on-replica") in
     step "get on-replica (main is reachable and misses) = %s" r;

     case "main unreachable, replica reachable";
     let dead_main =
       Fallback_backend.make
         ~sync:[sub "main" (module Down)]
         ~deferred:[sub "replica" replica]
         ~fallbacks:[]
     in
     let (module DeadMain : Backend.S) = dead_main in
     let* r = get dead_main (k "on-replica") in
     step "get on-replica = %s" r;
     (* A replica is a complete copy, so its "no" still ends the read. *)
     let* r = get dead_main (k "nowhere") in
     step "get nowhere = %s" r;
     (* But a reachable replica does not stand in for the main: a write has
        nowhere authoritative to land. *)
     let* r =
       outcome
         (fun () -> "ok")
         (fun () ->
           let+ () = DeadMain.put ~key:(k "w") ~data:"x" () in
           Some ())
     in
     step "put w = %s" r;

     case "main + readOnly archive: different content, so a miss falls through";
     let with_arc =
       Fallback_backend.make
         ~sync:[sub "main" main]
         ~deferred:[]
         ~fallbacks:[sub "archive" archive]
     in
     let (module WithArc : Backend.S) = with_arc in
     let* r = get with_arc (k "on-archive") in
     step "get on-archive = %s" r;
     let* r = head with_arc (k "on-archive") in
     step "head on-archive = %s" r;
     let* r = get with_arc (k "nowhere") in
     step "get nowhere = %s" r;
     let* () = WithArc.put ~key:(k "fresh") ~data:"n" () in
     step "put fresh -> on main: %b, on archive: %b"
       (holds main_root (k "fresh"))
       (holds archive_root (k "fresh"));
     let* () = WithArc.delete ~key:(k "on-archive") () in
     step "delete on-archive -> still on archive: %b"
       (holds archive_root (k "on-archive"));

     case "main unreachable, archive behind it";
     let dead_to_arc =
       Fallback_backend.make
         ~sync:[sub "main" (module Down)]
         ~deferred:[]
         ~fallbacks:[sub "archive" archive]
     in
     let* r = get dead_to_arc (k "on-archive") in
     step "get on-archive = %s" r;
     (* The source of truth was never asked, so this is not a miss. *)
     let* r = get dead_to_arc (k "nowhere") in
     step "get nowhere = %s" r;

     case "reachable main, unreachable archive behind it";
     let dead_arc =
       Fallback_backend.make
         ~sync:[sub "main" main]
         ~deferred:[]
         ~fallbacks:[sub "archive" (module Down)]
     in
     (* The archive might have held it, so again not a miss. *)
     let* r = get dead_arc (k "nowhere") in
     step "get nowhere = %s" r;
     (* A key the main holds never reaches the archive at all. *)
     let* r = get dead_arc (k "on-main") in
     step "get on-main = %s" r;

     case "a read-only domain: archives only, nothing writable at all";
     let ro =
       Fallback_backend.make ~sync:[] ~deferred:[]
         ~fallbacks:[sub "archive" archive]
     in
     let (module Ro : Backend.S) = ro in
     let* r = get ro (k "on-archive") in
     step "get on-archive = %s" r;
     let* r = get ro (k "nowhere") in
     step "get nowhere = %s" r;
     let* r = listing ro "tsync/d/manifests/" in
     step "list manifests/ = %s" r;
     (* A write must fail rather than fan out over nothing and report success. *)
     let* r =
       outcome
         (fun () -> "ok")
         (fun () ->
           let+ () = Ro.put ~key:(k "nope") ~data:"x" () in
           Some ())
     in
     step "put nope = %s" r;
     let* r =
       outcome
         (fun () -> "ok")
         (fun () ->
           let+ () = Ro.delete ~key:(k "on-archive") () in
           Some ())
     in
     step "delete on-archive = %s" r;
     step "on-archive still there: %b" (holds archive_root (k "on-archive"));

     case "listings: an empty one is an answer, an unreachable backend is not";
     let* r = listing with_arc "tsync/d/nothing/" in
     step "list nothing/ on main = %s" r;
     let* r = listing dead_to_arc "tsync/d/manifests/" in
     step "list manifests/ with main unreachable = %s" r;
     Lwt.return_unit)
