(* format-merge §2 rule 1: an arrival during a settling schedules one more, and
   only copies still there schedule anything. *)
open Tsync_owner

let p fmt = Printf.printf (fmt ^^ "\n%!")
let copy = ".tsync-ext/totp/" ^ String.make 32 'a' ^ " (conflicted copy from b)"

let () =
  let t = Format_merge.create () in
  let runs = ref 0 and mid_arrival = ref true in
  let rec format =
    {
      Format_merge.name = "test";
      folder = ".tsync-ext/totp";
      settle =
        (fun () ->
          incr runs;
          (* A copy arrives while the first settling runs. *)
          if !mid_arrival then (
            mid_arrival := false;
            arrive [copy]));
    }
  and arrive paths =
    Format_merge.arrived t ~present:(fun _ -> true) ~spawn:(fun f -> f ()) paths
  in
  Format_merge.register t format;
  arrive [copy];
  p "settlings after an arrival during one: %d" !runs;
  runs := 0;
  arrive [copy];
  p "settlings after a lone arrival: %d" !runs;
  runs := 0;
  arrive [".tsync-ext/totp/" ^ String.make 32 'a'];
  p "settlings for a record that is no copy: %d" !runs;
  runs := 0;
  Format_merge.arrived t ~present:(fun _ -> false) ~spawn:(fun f -> f ()) [copy];
  p "settlings for a copy no longer there: %d" !runs
