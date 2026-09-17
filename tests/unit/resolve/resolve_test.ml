(* Every situation a peer's op can meet here and what is decided for it: the
   conflict table, whole, as the code holds it. A row that changes here is a
   change of policy, to be read against the ladder in {!Resolve}. *)

let bools = [false; true]

let universe =
  let open Resolve in
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
                  List.concat_map
                    (fun staged_under ->
                      List.map
                        (fun destination ->
                          Rename_folder
                            {
                              ours_owed;
                              source;
                              already_there;
                              staged_under;
                              destination;
                            })
                        [`Free; `Same_folder; `Another_folder])
                    bools)
                bools)
            [`At_path; `By_id; `Gone])
        bools;
      List.concat_map
        (fun source_here ->
          List.concat_map
            (fun staged_source ->
              List.map
                (fun staged_destination ->
                  Rename_file { source_here; staged_source; staged_destination })
                bools)
            bools)
        bools;
    ]

let () =
  List.iter
    (fun facts ->
      Printf.printf "%-98s -> %s\n"
        (Resolve.facts_to_string facts)
        (Resolve.decision_to_string (Resolve.decide facts)))
    universe;
  Printf.printf "\n%d situation(s)\n" (List.length universe)
