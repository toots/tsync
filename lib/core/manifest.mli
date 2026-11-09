(** The file manifest, binary [tsyncm04] (spec 02 §2.6): a frozen format read
    and written exactly as specified. *)

(** A manifest:
    - [body]: the exact bytes;
    - [mtime], [created]: nanoseconds since the epoch;
    - [name]: the leaf recorded at write time;
    - [link]: a symlink's target;
    - [h1]: the whole-file digest, seed 0, the content identity. *)
type t = private {
  body : string;
  size : int;
  mtime : int;
  created : int;
  chunk_size : int;
  count : int;
  name : string;
  link : string option;
  h1 : string;
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

(** The chunks a manifest body names; an error for a malformed key, which must
    never read as naming nothing. *)
val chunk_names : Bigstring.t -> (Chunk_key.t list, string) result

val is_link : t -> bool

(** The whole-file digest of a chunk list: [(h1, h2)]. *)
val digest_of : size:int -> cs:int -> Chunk_key.t list -> string * string

(** A regular file's manifest; [keys] has [max 1 ⌈size / chunk_size⌉] entries.
*)
val make :
  name:string ->
  size:int ->
  times:Fs.times ->
  chunk_size:int ->
  Chunk_key.t list ->
  t

val symlink : name:string -> times:Fs.times -> string -> t

(** The same content recorded under another leaf. *)
val rename : t -> string -> t

(** The same content with other times. *)
val times : t -> Fs.times

val with_times : t -> Fs.times -> t

(** [h1]. *)
val content_id : t -> string

(** CORRUPT for a chunk size a reader refuses, or a chunk list with a hole. *)
val check_readable : t -> unit

(** Same bytes: equal digests, size and link. *)
val equal_content : t -> t -> bool
