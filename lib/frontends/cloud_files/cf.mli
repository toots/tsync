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

(** Drops the local copy of an in-sync placeholder's content. *)
val dehydrate : string -> unit

(** Makes a placeholder whose content is whole on disk a plain file. *)
val revert : string -> unit

(** Every sync root registered for this user, as (id, path). *)
val registered : unit -> (string * string) list

(** A name as NTFS compares names, for case groups (§7.2). *)
val upcase : string -> string

(** An item as the take reads it (§9.3). *)
type state = {
  is_dir : bool;
  other_reparse : bool;  (** a link or another provider's reparse point *)
  placeholder : bool;
  in_sync : bool;
  identity : string;  (** empty unless [placeholder] *)
  usn : int64;  (** the volume's update sequence number of its last change *)
  unpopulated : bool;  (** a folder whose children were never asked *)
  dehydrated : bool;  (** some of its content is not on disk *)
  pin : [ `Unspecified | `Pinned | `Unpinned | `Excluded | `Inherit ];
}

(** [None] when nothing is at the path. *)
val state : string -> state option

(** The recursive change watch of a folder (§9.4). *)
type watch

val watch_open : string -> watch

(** Blocks for the next changes: (action, path relative to the folder), or
    [None] when events were lost. *)
val watch_read : watch -> (int * string) list option

val watch_close : watch -> unit

(** An item held open against other writers. *)
type held

(** [None] while another process holds the item open for writing. *)
val hold : string -> held option

val held_usn : held -> int64
val release : held -> unit

(** Stores [identity] on the held item, converting it when it is not a
    placeholder, and marks it in sync when [in_sync]; a placeholder also records
    [size], which an edit changed. *)
val set_identity :
  ?size:int -> held -> placeholder:bool -> string -> in_sync:bool -> unit

(** Makes one placeholder, in sync, in a folder outside any callback. *)
val create : string -> placeholder -> unit

(** Gives an in-sync placeholder the metadata and identity of [placeholder],
    dehydrating it when [dehydrate]; [false] when it changed since [usn] or is
    held for writing, which leaves it as it was. *)
val refresh : string -> usn:int64 -> placeholder -> dehydrate:bool -> bool
