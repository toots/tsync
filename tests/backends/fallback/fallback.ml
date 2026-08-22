(* Role composition, and how far a read is allowed to look.

   A write goes to the mains alone and waits for them; a replica is filled behind
   filling it, which is {!Deferred}'s business, not this one's. Mains and
   replicas hold the same content, so the first reachable one's "not found" ends
   the read. Read-only archives hold different content, so they answer both a
   miss and an unreachable source of truth, and are never written. A miss is
   reported only when every backend that could hold the key was asked: "could not
   look" must not reach a caller as "not there". *)

open Lwt.Syntax
open Check

let root = Scratch.dir "fallback"
let main_root = Filename.concat root "main"
let replica_root = Filename.concat root "replica"
let archive_root = Filename.concat root "archive"
let k name = "tsync/d/manifests/" ^ name

module Down = Doubles.Down (struct
  let why = "down"
end)

(* Distinguishable from [Down], so a report that names the wrong store is
   visible rather than merely wrong. *)
module Archive_down = Doubles.Down (struct
  let why = "archive down"
end)

let sub name backend = { Domain_store.name; backend }

(* A replica the read chain may reach. Filling one is {!Deferred}'s business,
   not this file's, so this one accepts nothing and only answers reads. *)
let readable name backend ~source:_ : (module Deferred.S) =
  (module struct
    let name = name
    let backend = backend
    let readable = Some backend
    let accept _ = Lwt.return_unit
    let skip _ = false
    let stats () = { Deferred.queued = 0; in_flight = 0; degraded = false }
  end)

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
  outcome (Printf.sprintf "%S") (fun () ->
      let+ body = B.get_opt ~key () in
      Option.map Bigstring.to_string body)

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
  let main =
    Backend.make ~backend_type:"local" ~get_field:(fun _ -> Some main_root) ()
  in
  let replica =
    Backend.make ~backend_type:"local"
      ~get_field:(fun _ -> Some replica_root)
      ()
  in
  let archive =
    Backend.make ~backend_type:"local"
      ~get_field:(fun _ -> Some archive_root)
      ()
  in
  let (module Rep : Backend.S) = replica in
  let (module Arc : Backend.S) = archive in
  Lwt_main.run
    (* Content each store has that the others do not. *)
    (let* () =
       Rep.put ~key:(k "on-replica")
         ~data:(Bigstring.of_string "from-replica")
         ()
     in
     let* () =
       Arc.put ~key:(k "on-archive")
         ~data:(Bigstring.of_string "from-archive")
         ()
     in

     case "one main, nothing behind it";
     let solo =
       Domain_store.make ~mains:[sub "main" main] ~targets:[] ~archives:[]
     in
     let (module Solo : Backend.S) = solo in
     let* () =
       Solo.put ~key:(k "on-main") ~data:(Bigstring.of_string "from-main") ()
     in
     step "put on-main";
     let* r = get solo (k "on-main") in
     step "get on-main = %s" r;
     let* r = get solo (k "nowhere") in
     step "get nowhere = %s" r;

     case "the only main is unreachable";
     (* Reporting a miss here would tell a caller the file is gone. *)
     let dead =
       Domain_store.make
         ~mains:[sub "main" (module Down)]
         ~targets:[] ~archives:[]
     in
     let* r = get dead (k "nowhere") in
     step "get nowhere = %s" r;
     let* r = head dead (k "nowhere") in
     step "head nowhere = %s" r;

     case "main + replica: same content, so a miss is authoritative";
     let with_rep =
       Domain_store.make
         ~mains:[sub "main" main]
         ~targets:[readable "replica" replica]
         ~archives:[]
     in
     let (module WithRep : Backend.S) = with_rep in
     (* The write waits for the main and nothing else: the replica is filled off
        this path. *)
     let* () =
       WithRep.put ~key:(k "both") ~data:(Bigstring.of_string "both") ()
     in
     step "put both -> on main: %b, on replica: %b"
       (holds main_root (k "both"))
       (holds replica_root (k "both"));
     (* The main is reachable and says no, so the replica is not consulted even
        though it happens to hold this one. *)
     let* r = get with_rep (k "on-replica") in
     step "get on-replica (main is reachable and misses) = %s" r;

     case "main unreachable, replica reachable";
     let dead_main =
       Domain_store.make
         ~mains:[sub "main" (module Down)]
         ~targets:[readable "replica" replica]
         ~archives:[]
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
           let+ () =
             DeadMain.put ~key:(k "w") ~data:(Bigstring.of_string "x") ()
           in
           Some ())
     in
     step "put w = %s" r;

     case "main + readOnly archive: different content, so a miss falls through";
     let with_arc =
       Domain_store.make
         ~mains:[sub "main" main]
         ~targets:[]
         ~archives:[sub "archive" archive]
     in
     let (module WithArc : Backend.S) = with_arc in
     let* r = get with_arc (k "on-archive") in
     step "get on-archive = %s" r;
     let* r = head with_arc (k "on-archive") in
     step "head on-archive = %s" r;
     let* r = get with_arc (k "nowhere") in
     step "get nowhere = %s" r;
     let* () =
       WithArc.put ~key:(k "fresh") ~data:(Bigstring.of_string "n") ()
     in
     step "put fresh -> on main: %b, on archive: %b"
       (holds main_root (k "fresh"))
       (holds archive_root (k "fresh"));
     let* () = WithArc.delete ~key:(k "on-archive") () in
     step "delete on-archive -> still on archive: %b"
       (holds archive_root (k "on-archive"));

     case "main unreachable, archive behind it";
     let dead_to_arc =
       Domain_store.make
         ~mains:[sub "main" (module Down)]
         ~targets:[]
         ~archives:[sub "archive" archive]
     in
     let* r = get dead_to_arc (k "on-archive") in
     step "get on-archive = %s" r;
     (* The source of truth was never asked, so this is not a miss. *)
     let* r = get dead_to_arc (k "nowhere") in
     step "get nowhere = %s" r;

     case "reachable main, unreachable archive behind it";
     let dead_arc =
       Domain_store.make
         ~mains:[sub "main" main]
         ~targets:[]
         ~archives:[sub "archive" (module Down)]
     in
     (* The archive might have held it, so again not a miss. *)
     let* r = get dead_arc (k "nowhere") in
     step "get nowhere = %s" r;
     (* A key the main holds never reaches the archive at all. *)
     let* r = get dead_arc (k "on-main") in
     step "get on-main = %s" r;

     case "a read-only domain: archives only, nothing writable at all";
     let ro =
       Domain_store.make ~mains:[] ~targets:[] ~archives:[sub "archive" archive]
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
           let+ () =
             Ro.put ~key:(k "nope") ~data:(Bigstring.of_string "x") ()
           in
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

     (* Which store the report names, when none of them could answer. The source
        of truth is the one that should have held it, so its failure is the one
        worth acting on; an archive's would send someone to the wrong machine. *)
     case "every store unreachable: the main's failure is the one reported";
     let all_dead =
       Domain_store.make
         ~mains:[sub "main" (module Down)]
         ~targets:[]
         ~archives:[sub "archive" (module Archive_down)]
     in
     let* r = get all_dead (k "nowhere") in
     step "get nowhere = %s" r;
     let* r = listing all_dead "tsync/d/manifests/" in
     step "list manifests/ = %s" r;
     Lwt.return_unit)
