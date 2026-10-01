(** The owner's request protocol (spec 08 §3): each request's type names its
    reply, so a caller gets a typed answer and the handler cannot answer the
    wrong shape. JSON exists only in the codec, which keeps the wire of 08 §3
    that the native shells speak. *)

open Tsync_core

(** An item named by reference or, for callers holding only a path, by its
    domain-relative path (08 §2.2). *)
type target = Ref of string | Rel of string

type availability = Online_only | Cached | Pinned of float

(** 08 §2.3. *)
type row = {
  ref_ : string;
  parent_ref : string;
  name : string;
  kind : [ `Dir | `File | `Symlink ];
  size : int;
  mtime : float;
  etag : string;
  is_uploaded : bool;
  content_id : string option;
  symlink_target : string option;
  availability : availability option;  (** files only *)
}

(** [unnamed] counts rows whose container has no id on this client. *)
type page = { items : row list; next : string option; unnamed : int }

(** A new item: a parent folder's reference and a leaf. *)
type destination = { parent_ref : string; name : string }

type written = { size : int; mtime : float; item : row }
type fetched = { local_path : string; offset : int; length : int }
type counted = { succeeded : int; failed : int }
type progress = Inactive | Active of { downloaded : int; total : int }
type resynced = Incremental of int | Full of { manifests : int; failed : int }
type trash_restored = Restored of int | Not_in_trash | Name_taken

type status = {
  domain : string;
  read_only : bool;
  paused : bool;
  pending_uploads : int;
  mount : string option;
}

type _ request =
  | Ping : unit request
  | Stat : target -> row request
  | List_dir : {
      dir : target;
      after : string option;
      limit : int option;
    }
      -> page request
  | Cursor : string request
  | Ensure_cached : { item : target; dest : string } -> string request
  | Fetch_range : {
      item : target;
      dest : string;
      offset : int;
      length : int;
    }
      -> fetched request
  | Download_progress : target -> progress request
  | Create : { at : destination; exclusive : bool } -> row request
  | Write : {
      at : destination;
      staging : string;
      base : string option;
      exclusive : bool;
    }
      -> written request
  | Mkdir : { at : destination; exclusive : bool } -> row request
  | Symlink : {
      at : destination;
      link_target : string;
      exclusive : bool;
    }
      -> row request
  | Rename : { src : string; at : destination; noreplace : bool } -> row request
  | Delete : target -> unit request
  | Rmdir : target -> unit request
  | Evict : target -> counted request
  | Restore : { item : target; keep : float option } -> counted request
  | Full_resync : unit request
  | Sync : { full : bool } -> resynced request
  | Trash_restore : string -> trash_restored request
  | Job : { job : Jobs.t; narrate : bool } -> int request
      (** the exit status; its lines stream before the reply (07 §2.5) *)
  | Cancel : int -> bool request  (** whether that job was running *)
  | Retry : int request  (** records re-adopted *)
  | Poll : unit request
  | Notify_reset : int request  (** subscribers reached *)
  | Status : status request
  | Pause : bool -> bool request  (** [false] resumes; the reply is the state *)
  | Stats : string list -> Tsync_status.Status_report.answer request
  | Stop : unit request

type packed = Request : 'a request -> packed

(** 08 §3.3's action string. *)
val action : 'a request -> string

(** M: refused on a read-only domain. *)
val mutates : 'a request -> bool

(** B: bounded by progress, not by the request deadline. *)
val bulk : 'a request -> bool

(** P: refused while paused. *)
val refused_while_paused : 'a request -> bool

(** An event on a domain's topic (08 §3.8). *)
type event = Recovered | Reset

val event_name : event -> string

(** Client side. *)
val encode : ?domain:string -> 'a request -> Yojson.Safe.t

(** A failure reply raises it with its code's kind (08 §2.4). *)
val decode_reply : 'a request -> Yojson.Safe.t -> 'a

(** Owner side; INVALID for a malformed request or an unknown action. *)
val decode : Yojson.Safe.t -> packed

val encode_reply : 'a request -> 'a -> Yojson.Safe.t

(** The row alone, for replies that carry one at the top level or nested. *)
val row_fields : row -> (string * Yojson.Safe.t) list

val row_of_fields : Yojson.Safe.t -> row
val failure_of_reply : Yojson.Safe.t -> Fail.t option

(** What a job streams before its reply: its id, then its output, its progress
    and, when asked for, its narration, as they happen. *)
type line =
  | Started of int
  | Out of string
  | Narration of string
  | Progress of { text : string; fraction : float option }

val line_to_json : line -> Yojson.Safe.t

(** One request over a socket, typed both ways; [bulk] is 07 §4.3's call, which
    a {!Job} always is, its lines going to [on_line]. *)
val call :
  ?bulk:bool ->
  ?timeout:float ->
  ?domain:string ->
  ?on_line:(line -> unit) ->
  string ->
  'a request ->
  'a
