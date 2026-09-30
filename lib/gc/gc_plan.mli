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
  | Open of { started : float option; after : string }
      (** open (or reopen) and mark the namespaces after [after] *)

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

type anchor = Live | In_trash | No_anchor

(** What expiry, or an on-demand purge, does for one trashed folder id, given
    its anchor and every trash entry naming it with its modification time
    (§4.1). *)
type trash =
  | Delete_stale of Key.t list  (** the folder is live: these entries only *)
  | Skip_recent  (** an entry is younger than the cutoff *)
  | Purge of Key.t list  (** purge the subtree, then delete these entries *)
  | Refuse_live  (** on demand, a folder anchored live elsewhere *)

val trash :
  anchor:anchor ->
  cutoff:float ->
  ?on_demand:bool ->
  (Key.t * float) list ->
  trash

(** Namespaces of a purged subtree with their depths, deepest first (§4.2). *)
val purge_order : (Key.prefix * int) list -> Key.prefix list

(** Versions whose key timestamp is older than the cutoff (§4.3); a key whose
    leaf is not a timestamp is not a version. *)
val versions : cutoff:float -> Key.t list -> Key.t list

(** Journal entries to delete (§4.4): older than the cutoff and than
    [now - horizon], never the one the cursor names. *)
val journal :
  now:float ->
  horizon:float ->
  cutoff:float ->
  cursor:Tsync_sync.Entry_key.t option ->
  (Tsync_sync.Entry_key.t * Key.t) list ->
  Key.t list

type share = Expired | Kept | Other_domain | Unparseable

(** A share body, for this domain's expiry (§4.5). *)
val share : domain:Domain_name.t -> now:float -> string -> share

type survey = { reclaimable : int; bytes : int; keys : Key.t list }

(** Chunks of a chunk-area listing that no reference names: the dry run's answer
    (§5.9). *)
val unreferenced :
  referenced:(Chunk_key.t -> bool) -> Tsync_store.Store.entry list -> survey
