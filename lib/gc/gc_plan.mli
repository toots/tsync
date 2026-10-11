(** Every decision of retention and collection that deletes or keeps data (spec
    algorithms/gc.md §4, §5.5), as pure functions of what was read. The
    effectful code reads, calls these, and acts on the answer; nothing here
    touches a store. *)

open Tsync_core

(** Where a collection session starts, from the run record it found (§5.5). *)
type start =
  | Resume_keep of string  (** abandoning, after this shard *)
  | Begin_keep  (** write an abandoning record, then keep every shard *)
  | Resume_close of { after : string; generation : int option }
      (** a closing record; [None] needs a fresh odd generation first *)
  | Open of { started : float option; after : string; marking : bool }
      (** open (or reopen) and mark the namespaces after [after]; [marking]: a
          run already marking, whose chunk space is never renamed aside again
          (gc.md §7) *)

(** An unreadable record is abandoning, the safe direction; an abandoning run
    stays abandoning; [keep] overrides every other phase. *)
val start : r0:Gc_record.read -> keep:bool -> start

(** Namespace tags [m/<dir>] and [v/<dir>] of the manifest and version areas,
    sorted, after the cursor. *)
val namespaces :
  manifests:string list -> versions:string list -> after:string -> string list

(** The directory prefix a tag names, with its trailing separator. *)
val namespace_prefix : Domain_name.t -> string -> Key.prefix

(** The run's odd generation from the current G: kept when odd, the next odd
    when even. An unreadable G has no successor: the run stops. *)
val closing_generation : int option -> (int, string) result

(** The even value G takes once every deletion of generation [g] settled. *)
val settled_generation : int -> int

(** Names in an outgoing shard that are chunk keys of that shard and absent from
    the surviving space; anything else is a leftover, never doomed. *)
val doomed :
  shard:string ->
  names:string list ->
  in_surviving:(Chunk_key.t -> bool) ->
  Chunk_key.t list

(** How an abandoned shard returns to the surviving space (§5.5 [keep_one]),
    from the entry counts of both sides. *)
type keep = Rename_shard | Push_down | Move_across

val keep_plan : surviving:int -> outgoing:int -> keep

(** Unit names after the cursor, sorted. *)
val after : cursor:string -> string list -> string list

(** Versions whose key timestamp is older than the cutoff (§4.1); a key whose
    leaf is not a timestamp is not a version. *)
val versions : cutoff:float -> Key.t list -> Key.t list

(** Log entries to delete, in ascending number order (publication §4.9): at or
    below the tree head, never the head entry, and older than [retention] by the
    modification time their store gave them. It stops at the first entry that
    stays, so the retained entries are contiguous. *)
val log :
  now:float ->
  retention:float ->
  tree_head:int ->
  (Key.t * float) list ->
  Key.t list

(** The takeover and void objects of entries the tree head has passed. *)
val takeovers : tree_head:int -> Key.t list -> Key.t list

type share = Expired | Kept | Other_domain | Unparseable

(** A share body, for this domain's expiry (§4.3). *)
val share : domain:Domain_name.t -> now:float -> string -> share

type survey = { reclaimable : int; bytes : int; keys : Key.t list }

(** Chunks of a chunk-area listing that no reference names: the dry run's answer
    (§5.9). *)
val unreferenced :
  referenced:(Chunk_key.t -> bool) -> Tsync_store.Store.entry list -> survey
