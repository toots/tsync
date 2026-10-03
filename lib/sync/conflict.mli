(** The two conflict decision tables (spec conflict-resolution §4): pure and
    total, so the policy can be printed exhaustively and tested apart from I/O.
    Fact gathering and enactment live with the engine. *)

(** What holds a local name (§3.5). *)
type occupant =
  | Nothing
  | File  (** a file record, no staged edit, not our rename's destination *)
  | Staged_file
  | Renamed_file  (** the destination of an unpublished file rename of ours *)
  | Folder_same  (** holding the op's own folder id *)
  | Folder_ours  (** another id, placed here by unpublished work of ours *)
  | Folder_published
  | Folder_no_id

(** Where the store's anchor files a folder id. *)
type place = In_trash | At of string | Place_unknown

(** The arrival actions of §4.6; the names they act on come from the facts. *)
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

(** The facts of §4.2, one shape per op. *)
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

(** The Arrival table (§4.3). *)
val arrival : arrival -> decision

(** Whether a decision is logged with its facts. *)
val clashed : decision -> bool

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

(** The Publish table (§4.5). *)
val publish : op_kind -> publish_fact -> publish_action list * ending

val publish_clashed : publish_fact -> bool

(** [conflict_name ~client ~is_dir leaf n], §4.7. *)
val conflict_name : client:string -> is_dir:bool -> string -> int -> string

val max_claim_rounds : int
val action_name : action -> string
val describe : decision -> string
