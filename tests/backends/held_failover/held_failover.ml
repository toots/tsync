(* Reads of a domain whose main has gone, with a replica behind it.

   The main is a store that climbs the real retry ladder against a link that
   fails, as a driver does, and says how it went to its own health. What is
   counted is how often it was asked: once it is known to be down a read does
   not go near it, and one read at a time finds out whether it is back. Nothing
   is timed. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "held-failover"
let key name = Stored_key.in_space ~prefix:"tsync/d/manifests/" name

let local name =
  Fixture.local_store ~verify_writes:false (Filename.concat root name)

type link = {
  up : bool ref;
  asked : int ref;
  attempts : int ref;
  health : Health.t;
}

let link () =
  { up = ref true; asked = ref 0; attempts = ref 0; health = Health.create () }

(* A driver in miniature: every read is a climb of the shared ladder, told whose
   link it is on. *)
let behind link (module Real : Backend_lwt.Store) : (module Backend_lwt.Store) =
  (module struct
    include Real

    let climbing op ask =
      incr link.asked;
      Retry_lwt.with_retry ~health:link.health ~max_attempts:3
        ~classify:Backend.classify ~name:"main" ~op (fun () ->
          incr link.attempts;
          if !(link.up) then ask ()
          else Lwt.fail (Retry.failed ~kind:Retry.Transient ~op "HTTP 502"))

    let get_opt ~key () = climbing "get_opt" (Real.get_opt ~key)
    let get ~key () = climbing "get" (Real.get ~key)

    let watch ~key ~last_seen () =
      climbing "watch" (fun () -> Real.watch ~key ~last_seen ())

    let get_many =
      Some
        (fun ~entries () ->
          climbing "get_many" (fun () ->
              Lwt_list.map_s
                (fun (e : Backend.file_entry) ->
                  let+ body = Real.get_opt ~key:e.Backend.key () in
                  (e.Backend.key, body))
                entries))

    let list_many = None
    let local_path = None
    let health = link.health
  end)

let readable name backend ~source:_ : (module Domain_store_lwt.Deferred.S) =
  (module struct
    let name = name
    let backend = backend
    let readable = Some backend
    let accept _ = Lwt.return_unit
    let skip _ = false
    let stats () = { Deferred.queued = 0; in_flight = 0; degraded = false }
  end)

let read (module D : Backend_lwt.Store) name =
  Lwt.catch
    (fun () ->
      let+ body = D.get_opt ~key:(key name) () in
      match body with
        | Some b -> Printf.sprintf "%S" (Bigstring.to_string b)
        | None -> "none")
    (fun exn -> Lwt.return ("raised: " ^ Retry.reason exn))

let put (module S : Backend_lwt.Store) name body =
  S.put ~key:(key name) ~data:(Bigstring.of_string body) ()

let () =
  Health.trip_span := 0.;
  let main_store = local "main" and replica_store = local "replica" in
  let main_link = link () and replica_link = link () in
  let main = behind main_link main_store
  and replica = behind replica_link replica_store in
  let domain =
    Domain_store_lwt.make
      ~mains:[{ Domain_store_lwt.name = "main"; backend = main }]
      ~targets:[readable "replica" replica]
      ~archives:[]
  in
  let alone =
    Domain_store_lwt.make
      ~mains:[{ Domain_store_lwt.name = "main"; backend = main }]
      ~targets:[] ~archives:[]
  in
  Lwt_main.run
    (let* () = put main_store "file" "from the main" in
     let* () = put replica_store "file" "from the replica" in

     case "both up";
     let* said = read domain "file" in
     step "read = %s" said;
     check "the main answers, and the replica is not asked"
       (!(main_link.asked) = 1 && !(replica_link.asked) = 0);

     case "the main's link goes";
     main_link.up := false;
     main_link.asked := 0;
     main_link.attempts := 0;
     let* said = read domain "file" in
     step "read = %s" said;
     check
       "the read comes back from the replica, the main having been asked once"
       (!(main_link.asked) = 1 && Health.is_held main_link.health);
     (* The ladder has a third attempt in it, which is still to come. *)
     check "and not waited for past the failure that showed it was down"
       ~why:(fun () -> string_of_int !(main_link.attempts))
       (!(main_link.attempts) = !Health.trip_after);
     (* Long enough for the third attempt to have been made, had the request
        been left climbing behind the read that gave up on it. *)
     let* () = Lwt_unix.sleep 1.2 in
     check "and called back, not left to climb for nobody"
       ~why:(fun () -> string_of_int !(main_link.attempts))
       (!(main_link.attempts) = !Health.trip_after);
     main_link.asked := 0;
     let* said =
       Lwt_list.map_s (fun () -> read domain "file") [(); (); (); (); ()]
     in
     step "five more = %s" (String.concat ", " (List.sort_uniq compare said));
     check "none of which goes near the main" (!(main_link.asked) = 0);

     case "a batch, which is the main's to answer";
     let (module D : Backend_lwt.Store) = domain in
     let entries =
       [{ Backend.key = key "file"; size = 0; last_modified = 0.; etag = None }]
     in
     let* bodies = (Option.get D.get_many) ~entries () in
     step "batch = %s"
       (String.concat ", "
          (List.map
             (fun (_, b) ->
               match b with
                 | Some b -> Printf.sprintf "%S" (Bigstring.to_string b)
                 | None -> "none")
             bodies));
     check "is answered key by key from the replica instead"
       (!(main_link.asked) = 0);

     case "a long poll, once the hold has run out";
     Health.expire main_link.health;
     main_link.asked := 0;
     let (module D : Backend_lwt.Store) = domain in
     let* () =
       Lwt.pick
         [D.watch ~key:(key "file") ~last_seen:None (); Lwt_unix.sleep 0.2]
     in
     check "is not what finds out whether the main is back"
       (!(main_link.asked) = 0);
     let* (_ : string) = read domain "file" in
     check "which the next read is" (!(main_link.asked) = 1);

     case "the same main with nothing behind it";
     main_link.asked := 0;
     let* said = read alone "file" in
     step "read = %s" said;
     check "is asked all the same, being all there is" (!(main_link.asked) = 1);

     case "the replica gone too";
     replica_link.up := false;
     let* said = read domain "file" in
     step "read = %s" said;
     check "is a read that failed, not a file that is not there"
       (String.length said > 6 && String.sub said 0 6 = "raised");
     replica_link.up := true;

     case "the hold runs out with the main back";
     main_link.up := true;
     main_link.asked := 0;
     Health.expire main_link.health;
     let* said = Lwt_list.map_p (fun () -> read domain "file") [(); (); ()] in
     step "three at once = %s" (String.concat ", " (List.sort compare said));
     check "one of them was spent finding out" (!(main_link.asked) = 1);
     let* said = read domain "file" in
     step "the next read = %s" said;
     check "and the main answers again" (not (Health.is_held main_link.health));

     case "a key the main does not have, the main being up";
     let* said = read domain "nowhere" in
     step "read = %s" said;
     check "is not there, which is an answer" (said = "none");
     Scratch.cleanup root;
     Lwt.return_unit);
  report ~expected:13 ()
