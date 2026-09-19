(* Whether a member that is not the main may be written.

   The rule is the guard's alone, so it is asked the way a command asks it: with
   the members of a domain and the one about to be written. The main is a store
   climbing the real retry ladder against a link, as a driver does, which is how
   the guard comes to know anything about it. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "write-guard"
let cursor_key = Stored_key.in_space ~prefix:"tsync/testdom/" "cursor"

type link = { mutable answers : [ `Yes | `Fails | `Never ]; asked : int ref }

let behind link cell (module Real : Backend_lwt.Store) :
    (module Backend_lwt.Store) =
  (module struct
    include Real

    let get_opt ~key () =
      incr link.asked;
      Retry_lwt.with_retry ~health:cell ~max_attempts:2
        ~classify:Backend.classify ~name:"main" ~op:"get_opt" (fun () ->
          match link.answers with
            | `Yes -> Real.get_opt ~key ()
            | `Fails ->
                Lwt.fail
                  (Retry.failed ~kind:Retry.Transient ~op:"get" "HTTP 530")
            | `Never -> fst (Lwt.wait ()))

    let get_many = None
    let list_many = None
    let local_path = None

    (* Named apart from the field: [include Real] has a [health] of its own in
       scope by here. *)
    let health = cell
  end)

let undated text =
  String.concat ""
    (List.map
       (fun c -> if c >= '0' && c <= '9' then "" else String.make 1 c)
       (List.init (String.length text) (String.get text)))

let asked_of guard =
  Lwt.catch
    (fun () ->
      let+ () = guard () in
      "allowed")
    (fun exn ->
      Lwt.return
        (Printf.sprintf "%s [%s%s]"
           (undated (Retry.reason exn))
           (Retry.string_of_kind (Retry.classify_in_order exn))
           (if exn = Backend.Not_writable then ", not writable" else "")))

let rec files dir =
  if not (Sys.file_exists dir) then []
  else
    List.concat_map
      (fun name ->
        let path = Filename.concat dir name in
        if Sys.is_directory path then files path else [path])
      (List.sort compare (Array.to_list (Sys.readdir dir)))

let () =
  Health.trip_span := 0.;
  Health.probe_timeout := 1.;
  let replica_root = Filename.concat root "replica" in
  let main_store = Fixture.local_store (Filename.concat root "main")
  and replica_store = Fixture.local_store replica_root in
  let domain link health =
    let main =
      Backend.member ~role:`Main ~name:"main" (behind link health main_store)
    and replica = Backend.member ~role:`Replica ~name:"replica" replica_store in
    ([main; replica], main, replica)
  in
  let ensure members dst () =
    Write_guard_lwt.ensure ~members ~cursor_key ~what:"copy to replica" dst
  in
  let said = function `Ok -> "ok" | `Offline why -> undated why in
  Lwt_main.run
    (case "a main this process has not heard from, and which is there";
     let link = { answers = `Yes; asked = ref 0 } in
     let members, main, replica = domain link (Health.create ()) in
     let* answer = asked_of (ensure members replica) in
     step "write the replica: %s" answer;
     check "is looked at once" (!(link.asked) = 1);
     let* (_ : string) = asked_of (ensure members replica) in
     let* (_ : string) = asked_of (ensure members replica) in
     check "and taken at its word after that" (!(link.asked) = 1);
     let* answer = asked_of (ensure members main) in
     step "write the main: %s" answer;
     check "which is not what is being guarded, and costs nothing"
       (!(link.asked) = 1);

     case "one that is not there";
     let link = { answers = `Fails; asked = ref 0 } in
     let health = Health.create () in
     let members, main, replica = domain link health in
     step "before anybody looks: %s" (said (Write_guard_lwt.state members));
     let* answer = asked_of (ensure members replica) in
     step "write the replica: %s" answer;
     check "is looked at, and found out"
       (!(link.asked) = 1 && Health.is_held health);
     step "once known: %s" (said (Write_guard_lwt.state members));
     let* answer = asked_of (ensure members main) in
     step "write the main: %s" answer;
     check
       "the main is still the main's to be written, which is how it is refilled"
       (answer = "allowed");

     case "one that never answers";
     let link = { answers = `Never; asked = ref 0 } in
     let members, _, replica = domain link (Health.create ()) in
     let* answer = asked_of (ensure members replica) in
     step "write the replica: %s" answer;
     check "is not waited on for ever" (!(link.asked) = 1);

     case "a domain with no main at all";
     let members =
       [Backend.member ~role:`ReadOnly ~name:"archive" replica_store]
     in
     step "%s" (said (Write_guard_lwt.state members));
     let* answer = asked_of (ensure members (List.hd members)) in
     step "write its store: %s" answer;
     check "has no source of truth to be behind" (answer = "allowed");

     case "a command that writes to every member, the main being gone";
     let link = { answers = `Fails; asked = ref 0 } in
     let members, _, _ = domain link (Health.create ()) in
     let module C =
       (val Fixture.conf ~domain:"testdom" ~store:main_store ~members ~root ())
     in
     let module I = Integrity_lwt.Make (C) in
     let before = files replica_root in
     let* answer =
       asked_of (fun () ->
           let+ (_ : [ `Watched | `Nothing_queued ]) =
             I.verify
               ~on_answers:(fun _ -> ())
               ~on_progress:(fun ~store:_ ~left:_ ~found:_ -> ())
               ~on_done:(fun ~store:_ ~found:_ -> ())
               ~on_stalled:(fun ~store:_ -> ())
               ()
           in
           ())
     in
     step "data-integrity --verify: %s" answer;
     check "leaves the replica holding exactly what it held"
       (files replica_root = before);
     link.answers <- `Yes;
     let members, _, _ = domain link (Health.create ()) in
     let module C =
       (val Fixture.conf ~domain:"testdom" ~store:main_store ~members ~root ())
     in
     let module I = Integrity_lwt.Make (C) in
     let* answer =
       asked_of (fun () ->
           let+ (_ : [ `Watched | `Nothing_queued ]) =
             I.verify
               ~on_answers:(fun _ -> ())
               ~on_progress:(fun ~store:_ ~left:_ ~found:_ -> ())
               ~on_done:(fun ~store:_ ~found:_ -> ())
               ~on_stalled:(fun ~store:_ -> ())
               ()
           in
           ())
     in
     step "and with the main there: %s" answer;
     check "which is the same command allowed" (answer = "allowed");
     Scratch.cleanup root;
     Lwt.return_unit);
  report ~expected:9 ()
