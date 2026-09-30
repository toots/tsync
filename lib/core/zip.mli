(** Streaming ZIP64 archives of unknown total size (spec 01 §13): STORED only, a
    data descriptor after each member, UTF-8 names. *)

type t

(** Every byte of the archive goes to [out], in order. *)
val create : (string -> unit) -> t

val add_dir : ?mode:int -> t -> name:string -> mtime:float -> unit

(** [body feed] produces the member by calling [feed] with successive pieces. *)
val add_file :
  ?mode:int ->
  t ->
  name:string ->
  mtime:float ->
  ((string -> unit) -> unit) ->
  unit

(** Write the central directory and the end records. *)
val finish : t -> unit

(** CRC-32 (polynomial 0xEDB88320) of a substring, continuing from [crc]. *)
val crc_update : int32 -> string -> int -> int -> int32
