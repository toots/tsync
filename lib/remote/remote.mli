(** Content and manifests on a domain's store (spec 02 §3–4): chunk upload with
    deduplication, verified downloads, manifests by slot, version history and
    the corruption memo. *)

open Tsync_core
open Tsync_store

(** Where the bytes of chunk [i] come from, decided without I/O: a key reused as
    is, or bytes produced when needed. *)
type source =
  | Stored of Chunk_key.t
  | Bytes of string
  | Lazy of (unit -> string)

(** The bytes offered for a chunk no longer match what the upload started from.
*)
exception Source_changed of string

(** The collection generation G (02 §2.12); absent reads as 0, unreadable as
    [None]. *)
val read_generation : Store.t -> Domain_name.t -> int option

module Make (_ : Context.S) : sig
  (** Whether a collection run is open on the main (cached briefly unless
      [fresh]). *)
  val run_present : ?fresh:bool -> unit -> bool

  (** The collection generation G; absent reads as 0, unreadable as [None]. *)
  val generation : unit -> int option

  (** The chunk size of new files (01 §3.5). *)
  val chunk_size : unit -> int

  (** A chunk marked corrupt on a verifying member (memo refreshed every 5 s).
  *)
  val is_marked : Chunk_key.t -> bool

  (** Drop chunks from the deduplication memo (after a "missing chunks"
      refusal). *)
  val drop_memo : Chunk_key.t list -> unit

  val put_chunk : Chunk_key.t -> string -> unit

  (** From either space during a collection; CORRUPT when no store holds it. *)
  val get_chunk : Chunk_key.t -> string

  (** Fails unless the body hashes to its key within two reads. *)
  val get_verified_chunk : Chunk_key.t -> string

  val get_chunk_range : Chunk_key.t -> int -> int -> string

  (** Put every chunk the store does not know and build the manifest; nothing is
      published. A marked chunk is re-sent rather than deduplicated. *)
  val upload_chunks :
    ?cancel:bool Atomic.t ->
    ?progress:(int -> unit) ->
    name:string ->
    size:int ->
    chunk_size:int ->
    mtime:float ->
    (int -> source) ->
    Manifest.t

  val get_slot : Folder_id.t -> string -> string option
  val head_slot : Folder_id.t -> string -> Store.entry option

  (** Snapshot the replaced body when versioning (best effort, bounded). *)
  val save_version : Key.t -> unit

  (** Put a manifest, saving a version first; on a "missing chunks" refusal the
      named chunks are re-sent from [resend] and the put retried. *)
  val put_manifest :
    ?resend:(Chunk_key.t -> string option) ->
    ?save:bool ->
    Key.t ->
    Manifest.t ->
    unit

  (** Publish at [(parent, leaf)], recording [leaf] as the manifest's name. *)
  val publish :
    ?resend:(Chunk_key.t -> string option) ->
    parent:Folder_id.t ->
    leaf:string ->
    Manifest.t ->
    unit

  (** Snapshot, then delete; answers whether a manifest was there. *)
  val delete_slot : Folder_id.t -> string -> bool

  (** Snapshots, gated copy, delete of the source, re-put with the new leaf. *)
  val rename_file : src:Folder_id.t * string -> dst:Folder_id.t * string -> unit

  (** Versions of a slot, newest first, with their timestamps in ns. *)
  val list_versions : Folder_id.t -> string -> (int64 * Store.entry) list

  val get_version : Store.entry -> string

  (** Put a version's body back at the slot (after snapshotting the current
      one). *)
  val revert : parent:Folder_id.t -> leaf:string -> Store.entry -> unit
end
