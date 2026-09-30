(** The chunk cache and its read path (spec algorithms/read-path-and-cache.md):
    groups of consecutive chunks stored as one local body, filled by range reads
    into partial bodies whose held intervals live only in memory, or fetched
    whole and verified before they are installed. *)

open Tsync_core

val read_deadline : float
val default_cache_chunk_size : int

(** A chunk of a group: its index in the file, key, length and offset in the
    group's body. *)
type member = { index : int; ck : Chunk_key.t; len : int; off : int }

type group = { gkey : string; members : member list; gsize : int }

(** Chunks per group for a manifest's own chunk size [cs] and the cache chunk
    size [cc], rounded to nearest. *)
val per : cs:int -> cc:int -> int

val group_key : Chunk_key.t list -> string
val group_of : cc:int -> Manifest.t -> int -> group
val groups : cc:int -> Manifest.t -> group list
val group_index : cc:int -> Manifest.t -> int -> int

type t

(** [fast] says a whole chunk costs about what a range does (a filesystem
    store); [get_whole] and [get_range] read the store. *)
val create :
  cache_root:string ->
  domain:Domain_name.t ->
  cc:int ->
  fast:(unit -> bool) ->
  get_whole:(Chunk_key.t -> Bigstring.t) ->
  get_range:(Chunk_key.t -> int -> int -> Bigstring.t) ->
  cap:int option ->
  t

val cc : t -> int
val whole_path : t -> string -> string
val is_whole : t -> string -> bool

(** Fetch every member, verify it, and install the group; concurrent callers
    share one fetch. *)
val ensure_whole : ?force:bool -> t -> group -> unit

(** Bytes [\[coff, coff + len)] of a member, fetching a range on a slow store
    and the whole group on a fast one; DEADLINE after {!read_deadline}, the
    fetch continuing. *)
val read_piece : t -> group -> member -> coff:int -> len:int -> Bigstring.t

(** A member from a whole, verified body, fetched if needed: the only source of
    inherited bytes in a new publication. *)
val verified_member : t -> group -> member -> Bigstring.t

val evict : t -> Manifest.t -> unit
val unpin : t -> Manifest.t -> unit

(** Pin every group until [until] (wall time), durably, then fetch them whole.
*)
val pin : t -> Manifest.t -> until:float -> unit

val availability :
  t -> Manifest.t -> [ `Online_only | `Cached | `Pinned of float ]

(** Whole groups and total groups. *)
val resident : t -> Manifest.t -> int * int

(** Hand a staged body to the cache under a group key: a hard link, else a copy
    on a root that cannot link. *)
val adopt_body : t -> string -> string -> unit

(** Remove every cache file that is not a whole body or a pin. *)
val sweep_at_start : t -> unit

type counts = { bytes : int; pinned : int; bodies : int }

(** Remove lapsed pins, then the coldest unpinned bodies over the cap. *)
val enforce_cap : t -> counts

(** What the last {!enforce_cap} left. *)
val last_counts : t -> counts option

val cap : t -> int option
