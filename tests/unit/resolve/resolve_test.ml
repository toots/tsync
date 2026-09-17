(* Every situation a peer's op can meet here and what is decided for it: the
   conflict table, whole, as the code holds it. A row that changes here is a
   change of policy, to be read against the ladder in {!Resolve}. *)

let bools = [false; true]

let universe =
  let open Resolve.Arrival in
  List.concat
    [
      List.concat_map
        (fun renamed_onto ->
          List.concat_map
            (fun folder ->
              List.map
                (fun staged -> Put { renamed_onto; folder; staged })
                bools)
            [`Absent; `Holds_id; `Holds_no_id])
        bools;
      List.map (fun staged -> Delete { staged }) bools;
      List.concat_map
        (fun lives_elsewhere ->
          List.concat_map
            (fun staged_file ->
              List.map
                (fun another_folder ->
                  Mkdir { lives_elsewhere; staged_file; another_folder })
                bools)
            bools)
        bools;
      List.map
        (fun target -> Rmdir { target })
        [`By_id; `At_path; `Held_by_another];
      List.concat_map
        (fun ours_owed ->
          List.concat_map
            (fun source ->
              List.concat_map
                (fun already_there ->
                  List.map
                    (fun destination ->
                      Rename_folder
                        { ours_owed; source; already_there; destination })
                    [`Free; `Same_folder; `Another_folder])
                bools)
            [`At_path; `By_id; `Gone])
        bools;
      List.concat_map
        (fun source_here ->
          List.map
            (fun staged_destination ->
              Rename_file { source_here; staged_destination })
            bools)
        bools;
    ]

let at_publish =
  let open Resolve.Publish in
  [Put]
  @ List.map (fun f -> Delete f) [`Gone_here; `A_file_here_again]
  @ List.map
      (fun f -> Mkdir f)
      [`Claimed; `Name_taken; `Gone_here; `Filed_elsewhere; `No_id]
  @ List.map
      (fun f -> Rmdir f)
      [`Published; `Never_published; `Already_trashed; `No_id]
  @ List.map
      (fun f -> Rename_folder f)
      [`Free; `Name_taken; `Filed_here_already; `Never_published; `Gone_here]
  @ List.map
      (fun f -> Rename_file f)
      [
        `Moved;
        `Landed;
        `Source_still_there;
        `Source_gone `Staged;
        `Source_gone `Published;
        `Source_gone `Absent;
      ]

let () =
  print_endline "=== a peer's op arriving";
  List.iter
    (fun facts ->
      Printf.printf "%-98s -> %s\n"
        (Resolve.Arrival.facts_to_string facts)
        (Resolve.Arrival.decision_to_string (Resolve.Arrival.decide facts)))
    universe;
  Printf.printf "\n%d situation(s)\n" (List.length universe);
  print_endline "\n=== this client's own op being published";
  List.iter
    (fun facts ->
      Printf.printf "%-98s -> %s\n"
        (Resolve.Publish.facts_to_string facts)
        (Resolve.Publish.decision_to_string (Resolve.Publish.decide facts)))
    at_publish;
  Printf.printf "\n%d situation(s)\n" (List.length at_publish)
