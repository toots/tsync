(** The file manifest, binary [tsyncm03] (spec 02 §2.6): a frozen format read
    and written exactly as specified. *)

open Tsync_core

type t = private {
  body : string;  (** the exact bytes *)
  size : int;
  mtime : float;
  chunk_size : int;
  count : int;
  name : string;  (** the leaf recorded at write time *)
  link : string option;  (** a symlink's target *)
  h1 : string;  (** the whole-file digest, seed 0: the content identity *)
  h2 : string;
}

(** [None] for a body that is not a manifest: another magic, a short or
    inconsistent length, a negative size. *)
val decode : string -> t option

(** A store body, decoded when it carries the manifest magic. *)
val of_body : Bigstring.t -> t option

val is_manifest : Bigstring.t -> bool

(** Chunk key [i], parsed when used; a malformed key is CORRUPT. *)
val key : t -> int -> Chunk_key.t

val keys : t -> Chunk_key.t list

(** The chunks a body names if it is a manifest, else none. *)
val chunk_names : Bigstring.t -> Chunk_key.t list

val is_link : t -> bool

(** The whole-file digest of a chunk list: [(h1, h2)]. *)
val digest_of : size:int -> cs:int -> Chunk_key.t list -> string * string

(** A regular file's manifest; [keys] has [max 1 ⌈size / chunk_size⌉] entries.
*)
val make :
  name:string ->
  size:int ->
  mtime:float ->
  chunk_size:int ->
  Chunk_key.t list ->
  t

val symlink : name:string -> mtime:float -> string -> t

(** The same content recorded under another leaf. *)
val rename : t -> string -> t

val with_mtime : t -> float -> t

(** [h1]. *)
val content_id : t -> string

(** CORRUPT for a chunk size a reader refuses, or a chunk list with a hole. *)
val check_readable : t -> unit

(** Same bytes: equal digests, size and link. *)
val equal_content : t -> t -> bool
