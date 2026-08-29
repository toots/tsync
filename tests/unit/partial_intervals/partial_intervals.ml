(* The one range a fill asks for, given what the body already holds.

   Every answer is contiguous, which is the property the whole scheme rests on:
   one interval per chunk means a fill can never owe two requests, and the price
   is that a gap between what is held and what is wanted comes along. Each line
   says which of the two is happening. *)

let show = function
  | None -> "already held"
  | Some (a, b) -> Printf.sprintf "fetch [%d,%d)" a b

let ask label ~have ~want =
  let got = Partial.missing ~have ~want in
  let extra =
    match (have, got) with
      | Some (a, b), Some (lo, hi) ->
          (* Anything asked for that is neither wanted nor missing: the gap, or
             the middle of a surrounded interval. *)
          let overlap = max 0 (min hi b - max lo a) in
          if overlap > 0 then Printf.sprintf " (%d already held)" overlap else ""
      | _ -> ""
  in
  let held =
    match have with
      | None -> "nothing"
      | Some (a, b) -> Printf.sprintf "[%d,%d)" a b
  in
  Printf.printf "  %-24s holds %-9s wants [%d,%d) -> %s%s\n" label held
    (fst want) (snd want) (show got) extra

let () =
  print_endline "=== a chunk nothing has touched";
  ask "first read" ~have:None ~want:(2, 5);

  print_endline "";
  print_endline "=== what is held already costs nothing";
  ask "the same range" ~have:(Some (2, 5)) ~want:(2, 5);
  ask "inside it" ~have:(Some (0, 8)) ~want:(3, 4);
  ask "its first byte" ~have:(Some (0, 8)) ~want:(0, 1);

  print_endline "";
  print_endline "=== growing at either end";
  ask "carrying on" ~have:(Some (0, 4)) ~want:(4, 8);
  ask "overlapping forwards" ~have:(Some (2, 6)) ~want:(4, 9);
  ask "backwards to the start" ~have:(Some (4, 8)) ~want:(0, 4);
  ask "overlapping backwards" ~have:(Some (2, 6)) ~want:(0, 4);

  print_endline "";
  print_endline "=== where one request means fetching more than was asked";
  (* The gap between the two comes too: two requests either side of it would be
     a second interval to keep, and a second round trip to pay for. *)
  ask "a hole beyond" ~have:(Some (0, 2)) ~want:(6, 8);
  ask "a hole before" ~have:(Some (6, 8)) ~want:(0, 2);
  (* Surrounded: the middle is fetched again rather than split in two. *)
  ask "surrounding it" ~have:(Some (3, 5)) ~want:(0, 8)
