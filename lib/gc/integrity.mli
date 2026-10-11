(** Integrity (spec 05 §4.10): what the tree holds that its log does not account
    for, the chunks a member marked corrupt, and the repair of those chunks. The
    tree report is read-only: a tree behind its log is brought up by projection,
    and nothing repairs the tree from a report. *)

open Tsync_core

type finding =
  | Disowned of { marker : Key.t; anchor : Folder.anchor option }
      (** a marker its folder's anchor does not name, or whose folder has none
      *)
  | Unmarked of { id : Folder_id.t; parent : Folder_id.t; name : string }
      (** a folder with an anchor and no filed marker *)
  | Unaccounted of { key : Key.t; found : string; expected : string option }
      (** a record that is not the value the last retained entry gives its key,
          a key such an entry gives a value and that has no record, or a record
          in the namespace of a folder with no anchor *)

(** [Behind]: an entry exists above the tree head, the records are between two
    trees, and no finding is made. *)
type tree =
  | Behind of { tree_head : int; head : int }
  | Findings of finding list

(** A chunk a member marked corrupt. *)
type corrupt = { member : string; chunk : Chunk_key.t }

type report = { tree : tree; corrupt : corrupt list }

val healthy : report -> bool
val describe : finding -> string

type chunk_repair =
  | Cleared  (** the marked member's own copy is sound: rewritten over itself *)
  | Repaired of string  (** from that member *)
  | Unrepairable

(** One member's verification: what its bucket function found once no request
    was left, or how many requests were left when it stopped following. A count
    is [None] when its listing failed. *)
type verified =
  | Unsupported  (** no confirmed bucket function *)
  | Done of { corrupt : int }  (** corruption markers on the member *)
  | Stalled of { left : int option; corrupt : int option }
      (** nothing moved for [stall_polls] polls: a function not deployed or not
          notified *)
  | Abandoned of { left : int option; corrupt : int option }
      (** cancelled; the queued requests stay and are still consumed *)

module Make (_ : Tsync_remote.Context.S) : sig
  val report : ?narrate:Narrate.t -> ?cancelled:(unit -> bool) -> unit -> report

  (** Queue a check of every chunk on each member with a confirmed bucket
      function, then follow each every [poll] seconds (default 3) until no
      request is left and its markers were counted. A failed listing counts as
      no progress, never as none left or none corrupt. *)
  val verify :
    ?narrate:Narrate.t ->
    ?cancelled:(unit -> bool) ->
    ?poll:float ->
    ?stall_polls:int ->
    unit ->
    (string * verified) list

  (** [source] restricts where a sound copy is read from. The local cache is
      never a source; no corruption marker is deleted here. *)
  val repair_chunks :
    ?narrate:Narrate.t ->
    ?apply:bool ->
    ?source:string ->
    ?cancelled:(unit -> bool) ->
    report ->
    (corrupt * chunk_repair) list
end
