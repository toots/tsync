(* What a process is to the link, and how it changes its mind.

   The daemon here is a script: it grants, refuses, or says nothing, and what
   was asked of it is kept. On the hand-turned clock, so a renewal happens
   when the test advances the interval and a retry when it advances the
   wait. What is pinned is each mode's contract and every transition
   between them: a lessee admits at its grant and runs no law, a refusal or
   three silences make it govern its own link, a daemon that comes back is
   leased from again, and an owner splits what the law chose between its
   own writes and everyone renewing. *)

open Lwt.Syntax
open Check
module U = Uplink.Make (Io_lwt.Core) (Fake_clock) (Uplink.Silent)

(* Flushed, so a run cut short still says which case it was in. *)
let case name =
  case name;
  flush stdout

let check ?why name ok =
  check ?why name ok;
  flush stdout

let mb = 1024 * 1024
let on = { Uplink_control.default_settings with enabled = true }

let rec settle n =
  if n = 0 then Lwt.return_unit
  else
    let* () = Lwt.pause () in
    settle (n - 1)

(* The scripted daemon. *)
type script = Grant of float | Refuse | Silent

let script = ref (Grant (4. *. float_of_int mb))
let asked : Yojson.Safe.t list ref = ref []

let send line =
  asked := Yojson.Safe.from_string line :: !asked;
  match !script with
    | Grant rate ->
        Lwt.return
          (Yojson.Safe.to_string
             (`Assoc
               [("ok", `Bool true); ("rate", `Float rate); ("interval", `Float 2.)]))
    | Refuse ->
        Lwt.return {|{"ok":false,"error":"unknown action: uplink","code":"invalid"}|}
    | Silent -> Lwt.fail Lwt_unix.Timeout

let last_asked key =
  match !asked with
    | `Assoc fields :: _ -> (
        match List.assoc_opt key fields with Some (`Int n) -> n | _ -> -1)
    | _ -> -1

let field u key = List.assoc_opt key (U.json u)
let state u = match field u "state" with Some (`String s) -> s | _ -> "?"

let int_field u key =
  match field u key with Some (`Int n) -> n | _ -> -1

let tick () =
  Fake_clock.advance 2.;
  settle 6

let () =
  Uplink_control.initial_rate := float_of_int mb;
  Uplink_control.tick_interval := 2.;
  Uplink_budget.stall_timeout := 60.;
  Uplink_budget.burst_seconds := 2.;
  Lwt_main.run
    (case "a lessee admits at what it is granted, and runs no law";
     Fake_clock.reset ();
     let g = U.create ~settings:on () in
     U.lease_through g ~send;
     let adm = U.admission g U.Background in
     (* In flight across the first renewal, answered before the second. *)
     let* () = adm.Uplink.acquire ~bytes:mb in
     let* () = tick () in
     check "leased, and says so" (U.mode g = U.Leased && state g = "leased");
     check "the first renewal said what was in flight"
       ~why:(fun () -> string_of_int (last_asked "inFlight"))
       (last_asked "inFlight" = mb && last_asked "completed" = 0);
     adm.Uplink.completed ~bytes:mb ~elapsed:1.;
     let* () = tick () in
     check "the second said what had completed since"
       (last_asked "inFlight" = 0 && last_asked "completed" = mb);
     (* Four megabytes a second granted: eight of burst, where the law's own
        starting rate would have two. *)
     let* () = adm.Uplink.acquire ~bytes:(8 * mb) in
     check "eight megabytes pass at once on the grant" (U.waiting g = 0);
     check "while the law was never stepped"
       (Uplink_control.rate (U.control g) = float_of_int mb
       && Uplink_control.state (U.control g) = Ramping);

     case "three renewals unanswered, and it governs its own link";
     script := Silent;
     let* () = tick () in
     let* () = tick () in
     check "two silences: still leased" (U.mode g = U.Leased);
     let* () = tick () in
     check "a third: local" (U.mode g = U.Local && state g <> "leased");
     (* A body made to wait while another completes, or the law would
        rightly grant no more. *)
     let adm = U.admission g U.Background in
     let* () = adm.Uplink.acquire ~bytes:(8 * mb) in
     adm.Uplink.completed ~bytes:(8 * mb) ~elapsed:1.;
     let held = U.acquire g ~class_:U.Background ~bytes:mb in
     let* () = settle 3 in
     let* () = tick () in
     let* () = tick () in
     check "and the law runs, doubling while nothing says otherwise"
       ~why:(fun () -> string_of_float (Uplink_control.rate (U.control g)))
       (Uplink_control.rate (U.control g) > float_of_int mb);

     case "a daemon that comes back is asked again, and leased from";
     script := Grant (3. *. float_of_int mb);
     let rec wait n = if n = 0 then Lwt.return_unit else let* () = tick () in wait (n - 1) in
     let* () = wait 16 in
     let* () = held in
     check "leased again within the retry wait" (U.mode g = U.Leased);
     check "at the new grant"
       ~why:(fun () -> string_of_int (int_field g "rateBytesPerSec"))
       (int_field g "rateBytesPerSec" = 3 * mb);

     case "refused on first contact, local at once";
     Fake_clock.reset ();
     script := Refuse;
     let g = U.create ~settings:on () in
     U.lease_through g ~send;
     let* () = U.acquire g ~class_:U.Background ~bytes:1024 in
     let* () = tick () in
     check "one refusal is enough" (U.mode g = U.Local);

     case "an owner answers renewals and splits what the law chose";
     Fake_clock.reset ();
     let o = U.create ~settings:on () in
     U.own o;
     U.lease_through o ~send;
     check "and ignores an offer to lease" (U.mode o = U.Owner);
     let wants = { Uplink_lease.idle with in_flight = 65536; waiting = 2 } in
     check "a newcomer is granted an even share of the starting rate at once"
       ~why:(fun () ->
         match U.lease_renewal o ~pid:7 wants with
           | Some (r, _) -> string_of_float r
           | None -> "none")
       (match U.lease_renewal o ~pid:7 wants with
         | Some (r, 2.) -> Float.abs (r -. (float_of_int mb /. 2.)) < 1.
         | _ -> false);
     let* () = tick () in
     (* The step ran the law too, which grew the rate: the split is of what
        the law now says. *)
     let total = Uplink_control.rate (U.control o) in
     check "after a step, the idle owner keeps the floor and the lessee the rest"
       ~why:(fun () ->
         Printf.sprintf "own %d of %.0f" (int_field o "ownRateBytesPerSec") total)
       (int_field o "ownRateBytesPerSec" = on.min_rate
       && (match U.lease_renewal o ~pid:7 wants with
            | Some (r, _) ->
                Float.abs (r -. (total -. float_of_int on.min_rate)) < 1.
            | None -> false));
     check "and the report lists the lessee"
       (match field o "lessees" with Some (`List [_]) -> true | _ -> false);

     case "a lessee's bytes in flight are what the owner probes for";
     let probed = ref 0 in
     U.attach o ~name:"store"
       ~held:(fun () -> false)
       ~timeouts:(fun () -> 0)
       ~probe:(fun () ->
         incr probed;
         Lwt.return_unit);
     let* () = tick () in
     check "the owner idle, the lessee not: a probe went" (!probed = 1);

     case "a lessee held back is what lets the owner's law grow";
     let before = Uplink_control.rate (U.control o) in
     ignore
       (U.lease_renewal o ~pid:7
          { Uplink_lease.idle with completed = 4 * mb; held_back = true });
     let* () = tick () in
     check "it grew, for the lessee's sake"
       (Uplink_control.rate (U.control o) > before);
     ignore (U.lease_renewal o ~pid:7 { Uplink_lease.idle with completed = 4 * mb });
     let before = Uplink_control.rate (U.control o) in
     let* () = tick () in
     check "and holds once the lessee says it is no longer"
       (Uplink_control.rate (U.control o) = before);

     case "the owner's own writes hold a share like any other";
     (* A line behind the owner too, and the lessee asking for all it can get:
        the two halve the rate. Neither body fits the bucket at once, so
        both are stepped through rather than awaited. *)
     ignore (U.lease_renewal o ~pid:7 wants);
     let first = U.acquire o ~class_:U.Background ~bytes:(2 * mb) in
     let waiting = U.acquire o ~class_:U.Background ~bytes:mb in
     let* () = settle 3 in
     let* () = tick () in
     let total = Uplink_control.rate (U.control o) in
     check "half each"
       ~why:(fun () ->
         Printf.sprintf "own %d of %.0f" (int_field o "ownRateBytesPerSec") total)
       (Float.abs (float_of_int (int_field o "ownRateBytesPerSec") -. (total /. 2.))
       <= 1.);
     let rec until_through n =
       if n = 0 || not (Lwt.is_sleeping waiting) then Lwt.return_unit
       else
         let* () = tick () in
         until_through (n - 1)
     in
     let* () = until_through 60 in
     let* () = first in
     let* () = waiting in

     report ~expected:19 ();
     Lwt.return_unit)
