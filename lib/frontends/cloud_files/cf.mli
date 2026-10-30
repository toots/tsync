(** The Cloud Filter API and the sync root registration, as the provider calls
    them (cloud-files §8.3, §9.1, §13). Each call blocks only its own thread; a
    failure raises [Failure] naming the HRESULT. *)

(** A callback, as {!on_callback} receives it on the system's thread. *)
type request = {
  kind :
    [ `Fetch_data
    | `Cancel_fetch_data
    | `Fetch_placeholders
    | `Cancel_fetch_placeholders
    | `Close_completion
    | `Dehydrate
    | `Delete
    | `Rename
    | `Other of int ];
  transfer : int64;
  request_key : int64;
  identity : string;  (** the placeholder's file identity, empty for the root *)
  path : string;  (** the item's full path *)
  file_size : int;
  process_id : int;  (** the process that caused it *)
  flags : int;
  offset : int;  (** the range fetched or cancelled *)
  length : int;
  optional_offset : int;
  optional_length : int;
  target : string;  (** a rename's destination path *)
}

(** One handler for every callback of every connection; it completes each
    request it is given before returning. *)
val on_callback : (request -> unit) -> unit

type connection

val connect : string -> connection
val disconnect : connection -> unit

(** The completion statuses of cloud-files §12. *)
type status =
  [ `Success
  | `Not_in_sync
  | `Collision
  | `Not_empty
  | `Access_denied
  | `Invalid
  | `Network_unavailable
  | `Unsuccessful
  | `Cancelled ]

val ack :
  connection -> request -> [ `Delete | `Rename | `Dehydrate ] -> status -> unit

(** A placeholder to create in the folder a [`Fetch_placeholders] names. *)
type placeholder = {
  name : string;
  is_dir : bool;
  size : int;
  mtime : float;
  identity : string;
  read_only : bool;
}

val transfer_placeholders :
  connection -> request -> status -> placeholder list -> unit

(** [length] bytes of [buffer] are the file's at [offset]. *)
val transfer_data :
  connection ->
  request ->
  status ->
  Tsync_core.Bigstring.t ->
  offset:int ->
  length:int ->
  unit

(** Registers the sync root, or updates its registration. *)
val register :
  id:string ->
  path:string ->
  display_name:string ->
  version:string ->
  icon:string ->
  unit

val unregister : string -> unit

(** The user's SID in its string form. *)
val user_sid : unit -> string

(** The file identity of the placeholder at a path, [None] when it is not one.
*)
val identity : string -> string option

(** Makes a placeholder's whole content local. *)
val hydrate : string -> unit

(** A name as NTFS compares names, for case groups (§7.2). *)
val upcase : string -> string
