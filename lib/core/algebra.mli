(** The change algebra (spec change-algebra): states keyed by folder id,
    commands, the order in which a set of commands is applied to a real tree,
    and the three-way merge. Pure: no I/O of its own, no clock.

    A state is a {!base}, read on demand, with changes over it, so a merge costs
    what the changed keys cost and never walks the tree. An arrival calls
    {!merge} over the local tree, then {!order} to enact the result; a push
    builds [R] with {!apply} and tests its batch with {!is_batch}; a projection
    calls {!order}. ['f] is a file's value, compared by the [equal] each
    function takes. *)

type place = { parent : Folder_id.t; name : string }

module Places : Map.S with type key = place

type key = [ `File of place | `Folder of Folder_id.t ]

val compare_key : key -> key -> int

(** A command (Definition 4): a key, the value before, the value after. *)
type 'f command =
  [ `File of place * 'f option * 'f option
  | `Folder of Folder_id.t * place option * place option ]

val key_of : 'f command -> key

(** Whether the values before and after are equal. *)
val is_null : equal:('f -> 'f -> bool) -> 'f command -> bool

(** A well-formed tree read on demand. [children d] is every key that occupies a
    place in [d]. *)
type 'f base = {
  file : place -> 'f option;
  folder : Folder_id.t -> place option;
  folder_at : place -> Folder_id.t option;
  children : Folder_id.t -> key list;
}

(** A state (Definition 2): a base and the keys changed over it. *)
type 'f t

val of_base : 'f base -> 'f t

(** The state where every key is ∅. *)
val empty : 'f t

val file : 'f t -> place -> 'f option
val folder : 'f t -> Folder_id.t -> place option

(** The folder or the root. *)
val present : 'f t -> Folder_id.t -> bool

(** The keys that occupy a place. *)
val occupants : 'f t -> place -> key list

val children : 'f t -> Folder_id.t -> key list

(** A well-formed state read as a base. *)
val to_base : 'f t -> 'f base

(** The state with each command's key set to its value after. *)
val apply : 'f t -> 'f command list -> 'f t

(** The keys changed over the base, with their values: for a state over
    {!empty}, the whole state. *)
val files : 'f t -> (place * 'f option) list

val folders : 'f t -> (Folder_id.t * place option) list

(** Definition 3 around [keys], which must hold every key changed over a
    well-formed base; [Error] describes the first violation. *)
val well_formed : 'f t -> key list -> (unit, string) result

(** Definition 6: [apply r commands] is well-formed. *)
val is_batch : 'f t -> 'f command list -> bool

(** One change of a real tree; [`Park] moves a folder to a temporary place. *)
type 'f step =
  [ `Set of 'f command | `Park of Folder_id.t * place option * place ]

(** [take ?limit ~temp from commands] (Theorem 3): [(steps, left)], where
    [steps] sets some of the commands in an order in which each is applicable
    and every intermediate state well-formed, a folder parked at [temp id] under
    the root where the constraints form a cycle, and [left] holds the commands
    that cannot be set without one of the others. The commands of [steps] are a
    batch of [from] (Definition 6). At most [limit] commands are set, more only
    to give a parked folder its place. *)
val take :
  ?limit:int ->
  temp:(Folder_id.t -> string) ->
  'f t ->
  'f command list ->
  'f step list * 'f command list

(** {!take} of a batch: every command is set; raises [Failure] otherwise. *)
val order :
  temp:(Folder_id.t -> string) -> 'f t -> 'f command list -> 'f step list

(** The state after [steps]. *)
val run : 'f t -> 'f step list -> 'f t

(** The result of a merge, as changes: [local] is [diff(L, N)], which the owner
    enacts; [pending] holds, for every key the merge read or made, the command
    from [M] to [N], null where the key ends with no before-value. *)
type 'f merged = {
  n : 'f t;
  local : 'f command list;
  pending : 'f command list;
  asides : (place * place) list;
      (** local files kept under a fresh key: [(from, to)] *)
  restored : Folder_id.t list;  (** folders R1 brought back *)
}

type rule = [ `R1 | `R2 | `R3 ]

(** [merge ~equal ~aside ~l ~before ~theirs ()] (Definition 7). [before] is one
    command per before-value, from [R] to [L]; [theirs] is one command per key
    fetched, whose value after is [M]'s. [aside ~taken ~is_dir name] is a name
    for which [taken] is false: one free in [N] and in [L], so a file moves
    aside before anything else is enacted. [priority] is the order in which the
    repair rules are tried. Raises [Failure] if the repair does not end, which
    Theorem 8 excludes. *)
val merge :
  ?priority:rule list ->
  equal:('f -> 'f -> bool) ->
  aside:(taken:(string -> bool) -> is_dir:bool -> string -> string) ->
  l:'f base ->
  before:'f command list ->
  theirs:'f command list ->
  unit ->
  'f merged
