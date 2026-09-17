module Arrival = struct
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
        destination : [ `Free | `Same_folder | `Another_folder ];
      }
    | Rename_file of { source_here : bool; staged_destination : bool }

  type reason =
    | Already_applied
    | Ours_publishes_later
    | Held_by_another
    | Nothing_to_move

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
    (* F12: an edit outlives a removal the way a rename does in F5, under its
       own name, nothing else holding it. *)
    | Delete { staged = true } -> Skip Ours_publishes_later
    | Delete { staged = false } -> Apply [Remove_file]
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
    | Rename_folder { destination = `Same_folder; _ } ->
        Apply [Retire_stale_source]
    (* D5. *)
    | Rename_folder { destination = `Another_folder; _ } ->
        Apply [Our_folder_aside `Published_as_rename; Move_folder]
    (* D9: what is staged under the folder moves with it, as D3 mirrored. *)
    | Rename_folder { destination = `Free; _ } -> Apply [Move_folder]
    (* F10: staged bytes move with their file, as F4 mirrored. F11: ours under
       the destination is another file, as F7 mirrored. *)
    | Rename_file { source_here; staged_destination } ->
        Apply
          (when_ staged_destination Our_staged_file_aside
          @ [(if source_here then Move_file else Adopt_theirs_at_destination)])

  let clashed = function
    | Skip (Already_applied | Nothing_to_move) -> false
    | Skip (Ours_publishes_later | Held_by_another) -> true
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
    | Rename_folder { ours_owed; source; already_there; destination } ->
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
            @ flag "already there" already_there)
    | Rename_file { source_here; staged_destination } ->
        "rename file: "
        ^ String.concat ", "
            ([(if source_here then "source here" else "source not here")]
            @ flag "destination staged" staged_destination)

  let reason_to_string = function
    | Already_applied -> "already applied"
    | Ours_publishes_later -> "ours publishes later"
    | Held_by_another -> "held by another folder"
    | Nothing_to_move -> "nothing to move"

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
end

module Publish = struct
  type facts =
    | Put
    | Delete of [ `A_file_here_again | `Gone_here ]
    | Mkdir of
        [ `No_id | `Gone_here | `Filed_elsewhere | `Claimed | `Name_taken ]
    | Rmdir of [ `No_id | `Already_trashed | `Never_published | `Published ]
    | Rename_folder of
        [ `Gone_here
        | `Filed_here_already
        | `Never_published
        | `Name_taken
        | `Free ]
    | Rename_file of
        [ `Moved
        | `Source_still_there
        | `Landed
        | `Source_gone of [ `Staged | `Published | `Absent ] ]

  type action =
    | Remove_from_store
    | Put_marker
    | Retire_to_trash
    | Move_marker
    | Ours_aside
    | Ours_aside_as_rename
    | Queue_upload
    | Republish_here

  type ending = Publish | Nothing_owed | Superseded | Again | Retry
  type decision = { actions : action list; ending : ending }

  let only ending = { actions = []; ending }

  let decide = function
    | Put -> only Publish
    (* F1, F3: the name holds a file again, a peer's that outlives the removal
       or this client's own, which its upload publishes. *)
    | Delete `A_file_here_again -> only Nothing_owed
    | Delete `Gone_here -> { actions = [Remove_from_store]; ending = Publish }
    | Mkdir `No_id -> { actions = [Put_marker]; ending = Publish }
    | Mkdir (`Gone_here | `Filed_elsewhere) -> only Nothing_owed
    | Mkdir `Claimed -> only Publish
    (* D6, K1: same id, a name of its own, claimed there on the next pass. *)
    | Mkdir `Name_taken -> { actions = [Ours_aside]; ending = Again }
    | Rmdir `No_id -> only Publish
    (* D7. *)
    | Rmdir (`Already_trashed | `Never_published) -> only Nothing_owed
    | Rmdir `Published -> { actions = [Retire_to_trash]; ending = Publish }
    | Rename_folder (`Gone_here | `Never_published) -> only Nothing_owed
    | Rename_folder `Filed_here_already -> only Publish
    (* D5. *)
    | Rename_folder `Name_taken ->
        { actions = [Ours_aside_as_rename]; ending = Superseded }
    | Rename_folder `Free -> { actions = [Move_marker]; ending = Publish }
    | Rename_file (`Moved | `Landed) -> only Publish
    | Rename_file `Source_still_there -> only Retry
    (* Gone from the store and gone here: there is nothing to move and nothing
       to publish in its place, and retrying would hold the queue for good. *)
    | Rename_file (`Source_gone `Absent) -> only Nothing_owed
    (* F5, F6: nothing on the store to move, and the name it was given clashes
       with nothing. *)
    | Rename_file (`Source_gone `Staged) ->
        { actions = [Queue_upload]; ending = Superseded }
    | Rename_file (`Source_gone `Published) ->
        { actions = [Republish_here]; ending = Superseded }

  let clashed { ending; _ } =
    match ending with
      | Nothing_owed | Superseded | Again -> true
      | Publish | Retry -> false

  let facts_to_string = function
    | Put -> "put"
    | Delete `A_file_here_again -> "delete: a file holds the name here again"
    | Delete `Gone_here -> "delete: gone here"
    | Mkdir `No_id -> "mkdir: recorded with no id"
    | Mkdir `Gone_here -> "mkdir: the folder is gone here"
    | Mkdir `Filed_elsewhere -> "mkdir: the store files the folder elsewhere"
    | Mkdir `Claimed -> "mkdir: the store granted the name"
    | Mkdir `Name_taken -> "mkdir: another folder holds the name"
    | Rmdir `No_id -> "rmdir: recorded with no id"
    | Rmdir `Already_trashed -> "rmdir: already in the trash"
    | Rmdir `Never_published -> "rmdir: the store never heard of the folder"
    | Rmdir `Published -> "rmdir: filed on the store"
    | Rename_folder `Gone_here -> "rename folder: gone here"
    | Rename_folder `Filed_here_already ->
        "rename folder: the store files it where it is here"
    | Rename_folder `Never_published ->
        "rename folder: the store never heard of the folder"
    | Rename_folder `Name_taken ->
        "rename folder: another folder holds the name"
    | Rename_folder `Free -> "rename folder: the name is free"
    | Rename_file `Moved -> "rename file: moved"
    | Rename_file `Source_still_there ->
        "rename file: failed, source still on the store"
    | Rename_file `Landed ->
        "rename file: failed, source gone and destination there"
    | Rename_file (`Source_gone `Staged) ->
        "rename file: source gone from the store, ours staged"
    | Rename_file (`Source_gone `Published) ->
        "rename file: source gone from the store, ours published"
    | Rename_file (`Source_gone `Absent) ->
        "rename file: source gone from the store, nothing here"

  let action_to_string = function
    | Remove_from_store -> "remove it from the store"
    | Put_marker -> "put its marker"
    | Retire_to_trash -> "retire it to the trash"
    | Move_marker -> "move its marker"
    | Ours_aside -> "ours aside"
    | Ours_aside_as_rename -> "ours aside, as a rename of its own"
    | Queue_upload -> "queue its upload"
    | Republish_here -> "publish it where it is here"

  let ending_to_string = function
    | Publish -> "publish"
    | Nothing_owed -> "nothing owed"
    | Superseded -> "superseded"
    | Again -> "again"
    | Retry -> "retry"

  let decision_to_string { actions; ending } =
    String.concat "; "
      (List.map action_to_string actions @ [ending_to_string ending])
end
