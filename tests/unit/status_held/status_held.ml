(* What a report costs a member that is held down, which is nothing: its state
   is known, and asking it again is the deadline it already cost spent a second
   time, by a report whose reader is waiting. *)

open Lwt.Syntax
open Check

let root = Scratch.dir "status-held"
let asked = ref 0
let cell = Health.create ()

module Real = (val Fixture.local_store (Filename.concat root "main"))

module Main : Backend_lwt.Store = struct
  include Real

  let get_opt ~key () =
    incr asked;
    Real.get_opt ~key ()

  let list_prefix ?max_keys ~prefix () =
    incr asked;
    Real.list_prefix ?max_keys ~prefix ()

  let capabilities ~prefix () =
    incr asked;
    Real.capabilities ~prefix ()

  let health = cell
end

module C =
  (val Fixture.conf ~domain:"testdom"
         ~store:(module Main : Backend_lwt.Store)
         ~members:
           [
             Backend.member ~role:`Main ~name:"main"
               (module Main : Backend_lwt.Store);
             Backend.member ~role:`Replica ~name:"replica"
               (Fixture.local_store (Filename.concat root "replica"));
           ]
         ~cache_root:root ~data_dir:root ~root ()
      : Conf_lwt.S)

module Diag = Diagnostics.Make (C)

(* Its own, with nothing remembered: a report served from the first one's window
   would ask nobody whatever this did. *)
module Cold = Diagnostics.Make (C)

let member name json = Yojson.Safe.Util.member name json

let backend name domain =
  List.find
    (fun b -> member "name" b = `String name)
    (Yojson.Safe.Util.to_list (member "backends" domain))

let () =
  Health.trip_span := 0.;
  Lwt_main.run
    (case "a main that is up";
     let* domain = Diag.domain_json () in
     check "is asked, which is how the report knows" (!asked > 0);
     check "and the domain has nothing to say about it"
       (member "mainOffline" domain = `Null
       && member "health" (backend "main" domain) = `Null);

     case "the same main, held down";
     ignore (Health.lost cell "HTTP 530");
     ignore (Health.lost cell "HTTP 530");
     asked := 0;
     let* domain = Cold.domain_json () in
     let main = backend "main" domain in
     check "is not asked at all"
       ~why:(fun () -> string_of_int !asked)
       (!asked = 0);
     check "says it is held, once"
       (member "reachable" main = `Bool false
       && member "health" main <> `Null
       && member "journal" main = `Null
       && member "corrupted" main = `Null);
     check "the domain says its main is offline"
       (member "mainOffline" domain <> `Null);
     check "and the replica is described as it is"
       (member "reachable" (backend "replica" domain) = `Bool true);
     Scratch.cleanup root;
     Lwt.return_unit);
  report ~expected:6 ()
