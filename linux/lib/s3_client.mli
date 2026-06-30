exception S3_error of string
exception Cancelled

type file_entry = {
  key : string;
  size : int;
  last_modified : float;
  content_type : string option;
}

type t

val make :
  bucket:string ->
  region:string ->
  access_key_id:string ->
  secret_access_key:string ->
  t

val put : t -> ?content_type:string -> key:string -> data:string -> unit -> unit
val get : t -> key:string -> unit -> string

(** Returns [None] if the key does not exist. Raises [Unix.Unix_error (EIO, …)]
    on other S3 errors. *)
val head_opt : t -> key:string -> unit -> file_entry option

(** Delete [key]; silently succeeds if the key does not exist. *)
val delete : t -> key:string -> unit -> unit

(** Batch-delete a list of keys, sending at most 1 000 per S3 request. *)
val delete_multi : t -> string list -> unit

(** Copy an object by fetching its body and re-uploading, preserving
    content-type. *)
val copy : t -> src_key:string -> dst_key:string -> unit -> unit

(** List all objects under [prefix], paginating automatically. *)
val list_all : t -> prefix:string -> unit -> file_entry list

(** Simulate a [delimiter='/'] listing under [prefix]. Returns
    [(files, subdirectory_names)] where [subdirectory_names] are the immediate
    child directory components (without the trailing slash). *)
val list_directory : t -> prefix:string -> unit -> file_entry list * string list

(** Upload a file, splitting it into chunks when it exceeds
    [Chunk_manifest.chunk_size]. Each chunk is content-addressed (skip upload if
    already present on S3). The manifest object is written to [key] when
    chunked. Raises [Cancelled] if [cancel] is set to [true] mid-upload. Returns
    [Some manifest] when chunked, [None] for single-part uploads. *)
val put_chunked :
  t ->
  key:string ->
  src_path:string ->
  ?cancel:bool Atomic.t ->
  chunk_prefix:string ->
  unit ->
  Chunk_manifest.t

(** Download [key] to [dst_path], reassembling chunks if the object is a
    manifest. Returns [Some manifest] when chunked, [None] otherwise. *)
val get_chunked :
  t ->
  key:string ->
  dst_path:string ->
  chunk_prefix:string ->
  Chunk_manifest.t option
