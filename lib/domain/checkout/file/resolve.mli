(** What a peer's op does here when it meets work this client has not published,
    decided from facts alone: no lock, no disk, no store.

    One person at several machines mostly avoids working in two places at once,
    so a clash is settled best effort, by the first rung that applies:

    + {b At once}, from what is known when the op arrives.
    + {b The same everywhere, losing nothing}: ops that do not clash are applied
      as they are.
    + {b When in doubt, a conflicted copy}: what of this client's is in the way
      and unpublished is published as [X (conflicted copy from client)].
    + {b Last, one side wins}: two writes to a file both already published.

    {!facts} is what is true here for what the op names; whatever stands in the
    way is this client's own and unpublished, or it was the peer's to settle.
    {!decide} is the ladder as a table, and [tests/unit/resolve] prints all of
    it. *)

type facts =
  | Put of {
      renamed_onto : bool;
          (** An unpublished rename of this client's brought a file of its own
              to the name. *)
      folder : [ `Absent | `Holds_id | `Holds_no_id ];
          (** A folder of this client's under the name. *)
      staged : bool;  (** Bytes written here and not uploaded. *)
    }
  | Delete of { staged : bool }
  | Mkdir of {
      lives_elsewhere : bool;
          (** The folder the op creates is already here under another path. *)
      staged_file : bool;
      another_folder : bool;
          (** A folder holding another id sits under the name. *)
    }
  | Rmdir of { target : [ `By_id | `At_path | `Held_by_another ] }
      (** Found by its id wherever it sits, or looked for at the op's path,
          which another folder may hold. *)
  | Rename_folder of {
      ours_owed : bool;
          (** An op of this client's on the folder is not published yet. *)
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
      (** This client's own op on the folder follows on the store, and whichever
          lands last is where the folder ends up everywhere. *)
  | Held_by_another
      (** The name is another folder's, which the op is not on. *)
  | Nothing_to_move
  | Unpublished_work_here

type action =
  | Retarget_our_rename
      (** Ours takes a conflicted name, and the rename owed for it is published
          to that name instead. *)
  | Our_folder_aside of [ `Published_as_rename | `Here_only ]
  | Our_staged_file_aside
      (** Keeps the upload it is owed, under its new name. *)
  | Rescue_staged_under
      (** What was written under a folder going away survives beside it. *)
  | Write_theirs
  | Remove_file
  | Make_folder
  | Remove_folder
  | Move_folder
  | Retire_stale_source
      (** The destination already holds the folder: the source is a copy that
          came back, and gives up the id. *)
  | Move_file
  | Adopt_theirs_at_destination

(** In order: what is in the way steps aside before the op itself is applied. *)
type decision = Skip of reason | Apply of action list

val decide : facts -> decision

(** Whether anything but the op itself happened, which is worth a log line. *)
val clashed : decision -> bool

val facts_to_string : facts -> string
val decision_to_string : decision -> string
