type occupant =
  | Nothing
  | File
  | Staged_file
  | Renamed_file
  | Folder_same
  | Folder_ours
  | Folder_published
  | Folder_no_id

type place = In_trash | At of string | Place_unknown

type action =
  | Write_theirs
  | Remove_file
  | Make_folder
  | Remove_folder
  | Move_folder
  | Fill_vacated
  | File_aside
  | File_aside_published
  | Folder_aside
  | Folder_aside_local
  | Retarget_our_rename
  | Rescue_ours_under
  | Rescue_theirs
  | Retire_stale_source
  | Revive_ours
  | Arrive
  | Source_rule

type decision = Skip of string | Apply of action list

type arrival =
  | Put_facts of {
      store_present : bool;
      removal : bool;
      occupant : occupant;
      base_differs_from_own_view : bool;
    }
  | Delete_facts of {
      store_present : bool;
      removal : bool;
      occupant : occupant;
    }
  | Mkdir_facts of {
      held : bool;
      place : place;
      removal : bool;
      occupant : occupant;
    }
  | Rmdir_facts of {
      restored : bool;
      target : [ `By_id | `At_path | `Held_by_another | `Gone ];
    }
  | Rename_dir_facts of {
      ours_owed : bool;
      place : place;
      source : [ `At_path | `By_id | `Gone ];
      already_there : bool;
      removal : bool;
      occupant : occupant;
    }
  | Rename_file_facts of {
      dst_present : bool;
      removal : bool;
      occupant : occupant;
    }

(* conflict-resolution §4.3, rows A3–A8, shared by put and a delete whose name
   was written again. *)
let put_rows = function
  | Nothing | File -> Apply [Write_theirs]
  | Staged_file -> Apply [File_aside; Write_theirs]
  | Renamed_file -> Apply [Retarget_our_rename; Write_theirs]
  | Folder_ours -> Apply [Folder_aside; Write_theirs]
  | Folder_published | Folder_same -> Skip "folder holds the name"
  | Folder_no_id -> Apply [Folder_aside_local; Write_theirs]

let arrival = function
  | Put_facts f ->
      if not f.store_present then Skip "superseded"
      else if f.removal then Apply [Rescue_theirs]
      else if f.occupant = File && f.base_differs_from_own_view then
        Apply [Revive_ours]
      else put_rows f.occupant
  | Delete_facts f ->
      if f.removal then Skip "already removed here"
      else (
        match f.occupant with
          | Staged_file | Renamed_file -> Skip "ours publishes later"
          | occ when f.store_present -> put_rows occ
          | Nothing -> Skip "already applied"
          | File -> Apply [Remove_file]
          | _ -> Skip "folder holds the name")
  | Mkdir_facts f ->
      if f.held then Skip "already applied"
      else if f.place = In_trash then Skip "removed since"
      else if f.removal then Apply [Rescue_theirs]
      else (
        match f.occupant with
          | Nothing -> Apply [Make_folder]
          | File -> Apply [File_aside_published; Make_folder]
          | Staged_file -> Apply [File_aside; Make_folder]
          | Renamed_file -> Apply [Retarget_our_rename; Make_folder]
          | Folder_ours | Folder_published | Folder_same ->
              Apply [Folder_aside; Make_folder]
          | Folder_no_id -> Apply [Make_folder])
  | Rmdir_facts f ->
      if f.restored then Skip "restored since"
      else (
        match f.target with
          | `Gone -> Skip "already applied"
          | `Held_by_another -> Skip "held by another folder"
          | `By_id | `At_path ->
              Apply [Rescue_ours_under; Remove_folder; Fill_vacated])
  | Rename_dir_facts f ->
      if f.ours_owed then Skip "ours publishes later"
      else if f.place = In_trash then Skip "removed since"
      else if f.source = `Gone then Skip "nothing to move"
      else if f.already_there then Skip "already applied"
      else if f.removal then Apply [Rescue_theirs]
      else (
        match f.occupant with
          | Nothing -> Apply [Move_folder; Fill_vacated]
          | Folder_same -> Apply [Retire_stale_source]
          | Folder_ours | Folder_published ->
              Apply [Folder_aside; Move_folder; Fill_vacated]
          | Folder_no_id ->
              Apply [Folder_aside_local; Move_folder; Fill_vacated]
          | File -> Apply [File_aside_published; Move_folder; Fill_vacated]
          | Staged_file -> Apply [File_aside; Move_folder; Fill_vacated]
          | Renamed_file ->
              Apply [Retarget_our_rename; Move_folder; Fill_vacated])
  | Rename_file_facts f ->
      let dest =
        if not f.dst_present then []
        else if f.removal then [Rescue_theirs]
        else (
          match f.occupant with
            | Folder_published | Folder_same -> []
            | Nothing | File -> [Arrive]
            | Staged_file -> [File_aside; Arrive]
            | Renamed_file -> [Retarget_our_rename; Arrive]
            | Folder_ours -> [Folder_aside; Arrive]
            | Folder_no_id -> [Folder_aside_local; Arrive])
      in
      Apply (dest @ [Source_rule])

let benign =
  ["already applied"; "nothing to move"; "superseded"; "already removed here"]

let clashed = function
  | Skip r -> not (List.mem r benign)
  | Apply acts ->
      List.exists
        (function
          | File_aside | File_aside_published | Folder_aside
          | Folder_aside_local | Retarget_our_rename | Rescue_ours_under
          | Rescue_theirs | Revive_ours | Retire_stale_source ->
              true
          | _ -> false)
        acts

type publish_fact =
  | Base_current
  | Store_moved_on
  | Here_again
  | Store_gone
  | Store_as_expected
  | Store_changed
  | No_id
  | Gone_here
  | Filed_elsewhere
  | Claimed
  | Name_taken
  | Already_trashed
  | Never_published
  | Published
  | Trashed
  | Filed_here_already
  | Destination_taken
  | Moved
  | Landed
  | Source_still_there
  | Source_gone of [ `Absent | `Staged | `Published ]

type ending = Publish | Nothing_owed | Superseded | Again | Retry

type publish_action =
  | P_ours_aside_file
  | P_remove_from_store
  | P_put_marker
  | P_ours_aside
  | P_retire_to_trash
  | P_ours_aside_as_rename
  | P_move_marker
  | P_retarget_our_rename
  | P_queue_upload
  | P_republish_here

type op_kind = [ `Put | `Delete | `Mkdir | `Rmdir | `Rename_dir | `Rename_file ]

(* conflict-resolution §4.5. *)
let publish (op : op_kind) fact =
  match (op, fact) with
    | `Put, Base_current -> ([], Publish)
    | `Put, Store_moved_on -> ([P_ours_aside_file], Superseded)
    | `Delete, Here_again -> ([], Nothing_owed)
    | `Delete, Store_gone -> ([], Publish)
    | `Delete, Store_as_expected -> ([P_remove_from_store], Publish)
    | `Delete, Store_changed -> ([], Nothing_owed)
    | `Mkdir, No_id -> ([P_put_marker], Publish)
    | `Mkdir, Gone_here -> ([], Nothing_owed)
    | `Mkdir, Filed_elsewhere -> ([], Nothing_owed)
    | `Mkdir, Claimed -> ([], Publish)
    | `Mkdir, Name_taken -> ([P_ours_aside], Again)
    | `Rmdir, No_id -> ([], Publish)
    | `Rmdir, Already_trashed -> ([], Nothing_owed)
    | `Rmdir, Never_published -> ([], Nothing_owed)
    | `Rmdir, Published -> ([P_retire_to_trash], Publish)
    | `Rename_dir, Gone_here -> ([], Nothing_owed)
    | `Rename_dir, Trashed -> ([], Nothing_owed)
    | `Rename_dir, Filed_here_already -> ([], Publish)
    | `Rename_dir, Never_published -> ([], Nothing_owed)
    | `Rename_dir, Name_taken -> ([P_ours_aside_as_rename], Superseded)
    | `Rename_dir, Claimed -> ([P_move_marker], Publish)
    | `Rename_file, Destination_taken -> ([P_retarget_our_rename], Again)
    | `Rename_file, Moved -> ([], Publish)
    | `Rename_file, Landed -> ([], Publish)
    | `Rename_file, Source_still_there -> ([], Retry)
    | `Rename_file, Source_gone `Absent -> ([], Nothing_owed)
    | `Rename_file, Source_gone `Staged -> ([P_queue_upload], Superseded)
    | `Rename_file, Source_gone `Published -> ([P_republish_here], Superseded)
    | _ -> ([], Retry)

let publish_clashed = function
  | Store_moved_on | Store_changed | Name_taken | Trashed | Destination_taken
  | Source_gone _ ->
      true
  | _ -> false

(* 4.7: the loser's conflicted name, the extension from the last dot unless
   that dot is the first character; a folder's leaf is never split. *)
let conflict_name ~client ~is_dir leaf n =
  let tag =
    if n <= 1 then Printf.sprintf " (conflicted copy from %s)" client
    else Printf.sprintf " (conflicted copy %d from %s)" n client
  in
  if is_dir then leaf ^ tag
  else (
    match String.rindex_opt leaf '.' with
      | Some i when i > 0 ->
          String.sub leaf 0 i ^ tag ^ String.sub leaf i (String.length leaf - i)
      | _ -> leaf ^ tag)

let max_claim_rounds = 16

let action_name = function
  | Write_theirs -> "write-theirs"
  | Remove_file -> "remove-file"
  | Make_folder -> "make-folder"
  | Remove_folder -> "remove-folder"
  | Move_folder -> "move-folder"
  | Fill_vacated -> "fill-vacated"
  | File_aside -> "file-aside"
  | File_aside_published -> "file-aside-published"
  | Folder_aside -> "folder-aside"
  | Folder_aside_local -> "folder-aside-local"
  | Retarget_our_rename -> "retarget-our-rename"
  | Rescue_ours_under -> "rescue-ours-under"
  | Rescue_theirs -> "rescue-theirs"
  | Retire_stale_source -> "retire-stale-source"
  | Revive_ours -> "revive-ours"
  | Arrive -> "arrive"
  | Source_rule -> "source-rule"

let describe = function
  | Skip r -> "skip (" ^ r ^ ")"
  | Apply l -> String.concat ", " (List.map action_name l)
