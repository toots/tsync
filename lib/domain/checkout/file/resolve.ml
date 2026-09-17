type facts =
  | Put of {
      renamed_onto : bool;
      folder : [ `Absent | `Holds_id | `Holds_no_id ];
      staged : bool;
    }
  | Delete of { staged : bool }
  | Mkdir of {
      lives_elsewhere : bool;
      staged_file : bool;
      another_folder : bool;
    }
  | Rmdir of { target : [ `By_id | `At_path | `Held_by_another ] }
  | Rename_folder of {
      ours_owed : bool;
      source : [ `At_path | `By_id | `Gone ];
      already_there : bool;
      staged_under : bool;
      destination : [ `Free | `Same_folder | `Another_folder ];
    }
  | Rename_file of {
      source_here : bool;
      staged_source : bool;
      staged_destination : bool;
    }

type reason =
  | Already_applied
  | Ours_publishes_later
  | Held_by_another
  | Nothing_to_move
  | Unpublished_work_here

type action =
  | Retarget_our_rename
  | Our_folder_aside of [ `Published_as_rename | `Here_only ]
  | Our_staged_file_aside
  | Rescue_staged_under
  | Write_theirs
  | Remove_file
  | Make_folder
  | Remove_folder
  | Move_folder
  | Retire_stale_source
  | Move_file
  | Adopt_theirs_at_destination

type decision = Skip of reason | Apply of action list

let when_ condition action = if condition then [action] else []

(* Rows name the conflict table of [tests/scenario/conflicts]. *)
let decide = function
  | Put { renamed_onto; folder; staged } ->
      Apply
        ((* F7, F8. The file a rename brought here carries its staged bytes
            with it, so it is not set aside a second time. *)
         when_ renamed_onto Retarget_our_rename
        (* K1. *)
        @ (match folder with
          | `Absent -> []
          | `Holds_id -> [Our_folder_aside `Published_as_rename]
          | `Holds_no_id -> [Our_folder_aside `Here_only])
        (* F9. *)
        @ when_ (staged && not renamed_onto) Our_staged_file_aside
        @ [Write_theirs])
  | Delete { staged } ->
      Apply (when_ staged Our_staged_file_aside @ [Remove_file])
  | Mkdir { lives_elsewhere = true; _ } -> Skip Already_applied
  | Mkdir { staged_file; another_folder; _ } ->
      Apply
        ((* K1. *)
         when_ staged_file Our_staged_file_aside
        (* D6. *)
        @ when_ another_folder (Our_folder_aside `Published_as_rename)
        @ [Make_folder])
  | Rmdir { target = `Held_by_another } -> Skip Held_by_another
  (* D7, D8. *)
  | Rmdir { target = `By_id | `At_path } ->
      Apply [Rescue_staged_under; Remove_folder]
  (* D2, D4. *)
  | Rename_folder { ours_owed = true; _ } -> Skip Ours_publishes_later
  | Rename_folder { source = `Gone; _ } -> Skip Nothing_to_move
  | Rename_folder { already_there = true; _ } -> Skip Already_applied
  | Rename_folder { staged_under = true; _ } -> Skip Unpublished_work_here
  | Rename_folder { destination = `Same_folder; _ } ->
      Apply [Retire_stale_source]
  (* D5. *)
  | Rename_folder { destination = `Another_folder; _ } ->
      Apply [Our_folder_aside `Published_as_rename; Move_folder]
  | Rename_folder { destination = `Free; _ } -> Apply [Move_folder]
  | Rename_file { source_here = true; staged_source = true; _ } ->
      Skip Unpublished_work_here
  | Rename_file { source_here = true; _ } -> Apply [Move_file]
  | Rename_file { source_here = false; staged_destination = true; _ } ->
      Skip Unpublished_work_here
  | Rename_file { source_here = false; _ } ->
      Apply [Adopt_theirs_at_destination]

let clashed = function
  | Skip (Already_applied | Nothing_to_move) -> false
  | Skip (Ours_publishes_later | Held_by_another | Unpublished_work_here) ->
      true
  | Apply actions ->
      List.exists
        (function
          | Retarget_our_rename | Our_folder_aside _ | Our_staged_file_aside
          | Retire_stale_source ->
              true
          | Rescue_staged_under | Write_theirs | Remove_file | Make_folder
          | Remove_folder | Move_folder | Move_file
          | Adopt_theirs_at_destination ->
              false)
        actions

let flag name set = if set then [name] else []

let listed = function
  | [] -> "nothing in the way"
  | names -> String.concat ", " names

let facts_to_string = function
  | Put { renamed_onto; folder; staged } ->
      "put: "
      ^ listed
          (flag "ours renamed onto the name" renamed_onto
          @ (match folder with
            | `Absent -> []
            | `Holds_id -> ["our folder there"]
            | `Holds_no_id -> ["our folder there, holding no id"])
          @ flag "staged" staged)
  | Delete { staged } -> "delete: " ^ listed (flag "staged" staged)
  | Mkdir { lives_elsewhere; staged_file; another_folder } ->
      "mkdir: "
      ^ listed
          (flag "the folder already here elsewhere" lives_elsewhere
          @ flag "our staged file there" staged_file
          @ flag "another folder there" another_folder)
  | Rmdir { target } -> (
      "rmdir: "
      ^
        match target with
        | `By_id -> "found by its id"
        | `At_path -> "looked for at its path"
        | `Held_by_another -> "its path held by another folder")
  | Rename_folder
      { ours_owed; source; already_there; staged_under; destination } ->
      "rename folder: "
      ^ String.concat ", "
          ((match source with
             | `At_path -> ["source at its path"]
             | `By_id -> ["source found by its id"]
             | `Gone -> ["source gone"])
          @ (match destination with
            | `Free -> ["destination free"]
            | `Same_folder -> ["destination holds the same folder"]
            | `Another_folder -> ["destination holds another folder"])
          @ flag "our own op on it owed" ours_owed
          @ flag "already there" already_there
          @ flag "staged under it" staged_under)
  | Rename_file { source_here; staged_source; staged_destination } ->
      "rename file: "
      ^ String.concat ", "
          ([(if source_here then "source here" else "source not here")]
          @ flag "source staged" staged_source
          @ flag "destination staged" staged_destination)

let reason_to_string = function
  | Already_applied -> "already applied"
  | Ours_publishes_later -> "ours publishes later"
  | Held_by_another -> "held by another folder"
  | Nothing_to_move -> "nothing to move"
  | Unpublished_work_here -> "unpublished work here"

let action_to_string = function
  | Retarget_our_rename -> "ours aside, its rename retargeted"
  | Our_folder_aside `Published_as_rename -> "our folder aside, as a rename"
  | Our_folder_aside `Here_only -> "our folder aside, here only"
  | Our_staged_file_aside -> "our staged file aside"
  | Rescue_staged_under -> "rescue what is staged under it"
  | Write_theirs -> "write theirs"
  | Remove_file -> "remove the file"
  | Make_folder -> "make the folder"
  | Remove_folder -> "remove the folder"
  | Move_folder -> "move the folder"
  | Retire_stale_source -> "retire the stale source"
  | Move_file -> "move the file"
  | Adopt_theirs_at_destination -> "adopt theirs at the destination"

let decision_to_string = function
  | Skip reason -> "skip (" ^ reason_to_string reason ^ ")"
  | Apply actions -> String.concat "; " (List.map action_to_string actions)
