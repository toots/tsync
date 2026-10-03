(** Integrity (spec 05 §4.10, gc.md §4.6): what is wrong with a domain's tree
    and chunks, and the repairs that put it right. Without [apply] a repair is a
    dry run: every read and decision, nothing written. *)

open Tsync_core

type finding =
  | Twice of { id : Folder_id.t; paths : string list }
  | Disowned of { marker : Key.t; anchor : Folder.anchor }
  | Trashed_live of { entry : Key.t; id : Folder_id.t }
  | Unanchored of {
      path : string;
      id : Folder_id.t;
      parent : Folder_id.t;
      name : string;
    }
  | Orphan of {
      id : Folder_id.t;
      name : string;  (** from its anchor, else its id *)
      parent : Folder_id.t option;  (** its anchor's *)
      objects : int;
      sample : Key.t list;  (** at most 3 *)
      newest : float;  (** its anchor's and objects' latest write *)
      top_level : bool;  (** its anchor's parent is not an orphan *)
    }

(** A chunk a member marked corrupt. *)
type corrupt = { member : string; chunk : Chunk_key.t }

type report = {
  findings : finding list;
      (** Twice (sorted), Disowned, Trashed_live, Unanchored, Orphan *)
  tombstones : int;  (** namespaces holding only their anchor *)
  unreadable : Key.t list;
      (** folders the walk could not read: the walk is incomplete, and no orphan
          is adopted from it (gc §4.6) *)
  corrupt : corrupt list;
}

val healthy : report -> bool
val describe : finding -> string

type tree_repair =
  | Deleted  (** the stale marker or trash entry *)
  | Anchored
  | Adopted  (** into the trash, at the root under its name *)
  | Young  (** an orphan younger than [orphan_grace] *)
  | Nested  (** an orphan inside another, considered once that one is adopted *)
  | Left  (** Twice: reported only *)
  | Incomplete
      (** an orphan, not adopted: the walk could not read every folder *)
  | Failed of string

type chunk_repair =
  | Cleared  (** the marked member's own copy is sound: rewritten over itself *)
  | Repaired of string  (** from that member *)
  | Unrepairable

(** One member's verification: what its bucket function found once no request
    was left, or how many requests were left when it stopped following. *)
type verified =
  | Unsupported  (** no confirmed bucket function *)
  | Done of { corrupt : int }  (** corruption markers on the member *)
  | Stalled of { left : int; corrupt : int }
      (** nothing moved for [stall_polls] polls: a function not deployed or not
          notified *)
  | Abandoned of { left : int; corrupt : int }
      (** cancelled; the queued requests stay and are still consumed *)

(** The journal retention horizon plus 7 days. *)
val orphan_grace : float

module Make (_ : Tsync_remote.Context.S) : sig
  val report : ?narrate:Narrate.t -> ?cancelled:(unit -> bool) -> unit -> report

  (** Stops before the next finding once [cancelled] holds, answering what it
      did. *)
  val repair_tree :
    ?narrate:Narrate.t ->
    ?apply:bool ->
    ?cancelled:(unit -> bool) ->
    ?now:float ->
    report ->
    (finding * tree_repair) list

  (** Queue a check of every chunk on each member with a confirmed bucket
      function, then follow each every [poll] seconds (default 3) until no
      request is left. A failed listing counts as no progress, never as none
      left. *)
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
