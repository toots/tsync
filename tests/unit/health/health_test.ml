(* When a member is taken out of the rotation, and what it takes to get back in.

   Nothing here waits a hold out: a hold is read off the length the cell chose,
   and its running out is said rather than slept for. *)

open Check

let said = function `Up -> "up" | `Probe -> "probe" | `Held -> "held"
let blip t = ignore (Health.lost t "HTTP 502")

let () =
  Health.trip_span := 0.;
  case "how many failures it takes";
  let t = Health.create () in
  check "a member nobody has asked has not been heard from"
    (not (Health.sampled t));
  check "one failure is a blip" (Health.lost t "HTTP 502" = `Up);
  check "and says so to whoever asks next" (Health.check t = `Up);
  check "a second in a row takes it out" (Health.lost t "HTTP 502" = `Tripped);
  check "for whoever asks" (Health.check t = `Held);
  check "and whoever is choosing" (Health.is_held t);
  check "which is something heard from it" (Health.sampled t);
  (* The seconds left are whatever the machine took to get here. *)
  step "%s"
    (String.concat ""
       (List.map
          (fun c -> if c >= '0' && c <= '9' then "" else String.make 1 c)
          (List.init
             (String.length (Health.describe t))
             (String.get (Health.describe t)))));

  case "an answer between two failures";
  let t = Health.create () in
  blip t;
  Health.answered t;
  check "starts the count again" (Health.lost t "HTTP 502" = `Up);

  case "a hold running out";
  let t = Health.create () in
  blip t;
  blip t;
  Health.expire t;
  check "lets whoever is choosing through" (not (Health.is_held t));
  let first = Health.check t in
  let second = Health.check t in
  let third = Health.check t in
  let asked = [first; second; third] in
  step "three ask at once: %s" (String.concat ", " (List.map said asked));
  check "and one of them is the probe"
    (List.length (List.filter (fun a -> a = `Probe) asked) = 1
    && List.length (List.filter (fun a -> a = `Held) asked) = 2);

  case "a probe that fails";
  let before = Health.hold_length t in
  check "leaves it out, and is news" (Health.lost t "HTTP 502" = `Tripped);
  check "for twice as long" (Health.hold_length t = 2. *. before);
  for _ = 1 to 12 do
    Health.expire t;
    ignore (Health.check t);
    blip t
  done;
  check "up to a limit" (Health.hold_length t = !Health.hold_max);

  case "a request that was already on its way when the member went out";
  let t = Health.create () in
  blip t;
  blip t;
  let before = Health.hold_length t in
  check "fails into the hold without being news"
    (Health.lost t "HTTP 502" = `Held);
  check "and without making it longer" (Health.hold_length t = before);

  case "failures that all came in the same instant";
  Health.trip_span := 3600.;
  let t = Health.create () in
  for _ = 1 to 8 do
    blip t
  done;
  check "are one bad moment, not a member that is down"
    (Health.check t = `Up && not (Health.is_held t));
  Health.trip_span := 0.;
  check "which the next one, the moment having lasted, is"
    (Health.lost t "HTTP 502" = `Tripped);

  case "somebody waiting on a member with somewhere else to go";
  let t = Health.create () in
  let told = ref 0 in
  let (_ : int) = Health.on_held t (fun () -> incr told) in
  let withdrawn = Health.on_held t (fun () -> told := !told + 100) in
  Health.off t withdrawn;
  blip t;
  check "hears nothing of a blip" (!told = 0);
  blip t;
  check "is told when it goes out, the one who withdrew is not" (!told = 1);
  Health.expire t;
  ignore (Health.check t);
  blip t;
  check "and only once" (!told = 1);

  case "a probe that is answered";
  Health.expire t;
  ignore (Health.check t);
  Health.answered t;
  check "puts it back" (Health.check t = `Up && not (Health.is_held t));
  blip t;
  blip t;
  check "and the next hold is a first one again"
    (Health.hold_length t = !Health.hold_initial);
  check "with nothing to say once it is back"
    (Health.answered t;
     Health.json t = [] && Health.describe t = "");

  case "a probe nobody reports back from";
  let t = Health.create () in
  blip t;
  blip t;
  Health.expire t;
  check "is given out" (Health.check t = `Probe);
  check "and the member is held again meanwhile" (Health.check t = `Held);
  Health.expire t;
  check "until the next one" (Health.check t = `Probe);

  case "a store with no link to lose";
  for _ = 1 to 10 do
    blip Health.always_up
  done;
  check "is never out" (Health.check Health.always_up = `Up);
  check "and counts as heard from" (Health.sampled Health.always_up);
  report ~expected:28 ()
