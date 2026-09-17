(** How work done at two clients at once is settled, decided from facts alone:
    no lock, no disk, no store.

    One person at several machines mostly avoids working in two places at once,
    so a clash is settled best effort, by the first rung that applies:

    + {b At once}, from what is known when the op arrives.
    + {b The same everywhere, losing nothing}: ops that do not clash are applied
      as they are.
    + {b When in doubt, a conflicted copy}: what of this client's is in the way
      and unpublished is published as [X (conflicted copy from client)].
    + {b Last, one side wins}: two writes to a file both already published.

    A clash is met at two moments, each a table here: when a peer's op arrives
    ({!Arrival}) and when this client's own is published to a store that moved
    on since ({!Publish}). [tests/unit/resolve] prints both whole. *)

module Arrival : sig
  (** A peer's op arriving. {!Arrival.facts} is what is true here for what it
      names; whatever stands in the way is this client's own and unpublished, or
      it was the peer's to settle. *)

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
        destination : [ `Free | `Same_folder | `Another_folder ];
      }
    | Rename_file of { source_here : bool; staged_destination : bool }

  type reason =
    | Already_applied
    | Ours_publishes_later
        (** This client's own op on the same thing follows on the store, and
            whichever lands last is what everyone ends with. *)
    | Held_by_another
        (** The name is another folder's, which the op is not on. *)
    | Nothing_to_move

  type action =
    | Retarget_our_rename
        (** Ours takes a conflicted name, and the rename owed for it is
            published to that name instead. *)
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

  (** In order: what is in the way steps aside before the op itself is applied.
  *)
  type decision = Skip of reason | Apply of action list

  val decide : facts -> decision

  (** Whether anything but the op itself happened, which is worth a log line. *)
  val clashed : decision -> bool

  val facts_to_string : facts -> string
  val decision_to_string : decision -> string
end

(** This client's own op being published. A fact may be the answer to an
    attempt: a name is the store's to grant and a move the store's to make, so
    the claim and the move come first and the decision is about what they met.
*)
module Publish : sig
  type facts =
    | Put  (** The upload queue's, which publishes it with its bytes. *)
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
        (** [`Landed]: the source is gone and the destination there, so the move
            happened and what failed came after it. [`Source_gone] says what
            this client holds under the new name. *)

  type action =
    | Remove_from_store
    | Put_marker
    | Retire_to_trash
    | Move_marker
    | Ours_aside  (** Here only: its creation is published where it lands. *)
    | Ours_aside_as_rename
    | Queue_upload
    | Republish_here

  type ending =
    | Publish
    | Nothing_owed  (** The store is owed no word of it, and the record goes. *)
    | Superseded  (** Replaced by work under a record of its own. *)
    | Again  (** Decided afresh, what was in the way having moved. *)
    | Retry

  type decision = { actions : action list; ending : ending }

  val decide : facts -> decision

  (** Whether the op met anything but the store it was recorded against. *)
  val clashed : decision -> bool

  val facts_to_string : facts -> string
  val decision_to_string : decision -> string
end
