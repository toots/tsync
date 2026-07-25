val chunk_size : int

(** Current manifest body format version (2 = inode layout). *)
val current_version : int

type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

(** Per-chunk residency of a locally cached file. [Present] = fetched and
    matches the backend; [Absent] = a hole (never fetched); [Dirty] = written
    locally and not yet published (its [chunk_entry] hashes are stale until
    upload). *)
type chunk_st = Present | Absent | Dirty

type t = {
  v : int;
  name : string;  (** leaf name; authority for the file's own name *)
  size : int64;
  chunk_size : int;
  chunks : chunk_entry list;
  h1 : string;
  h2 : string;
  mtime : float;
  symlink : string option;
  residency : chunk_st array option;
      (** [None] = fully present and clean (the only form published to the
          backend); [Some a] = per-chunk state of a partially cached or edited
          file, index-aligned to [chunks]. *)
}

type state = [ `Dirty | `Clean of t ]

val chunk_key : chunk_entry -> string

(** Whole-file [h1]/[h2] as a hash over the ordered chunk digests, so a changed
    file's manifest is rebuildable from its chunk entries alone. *)
val digest_of_chunks : chunk_entry list -> string * string

val make :
  name:string ->
  h1:string ->
  h2:string ->
  size:int64 ->
  chunk_size:int ->
  chunks:chunk_entry list ->
  mtime:float ->
  state

(** A chunkless manifest representing a symlink to [target]. *)
val make_symlink : name:string -> target:string -> mtime:float -> state

val of_string : string -> state
val to_string : state -> string
