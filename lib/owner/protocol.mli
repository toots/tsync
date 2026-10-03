(** The owner's request protocol (spec 08 §3): each request's type names its
    reply, so a caller gets a typed answer and the handler cannot answer the
    wrong shape. JSON exists only in the codec, which keeps the wire of 08 §3
    that the native shells speak. *)

open Tsync_core
module R = Tsync_status.Status_report

type availability = Online_only | Cached | Pinned of float

(** A new item: a parent folder's reference and a leaf. *)
type destination = { parent_ref : string; name : string }

(** An item named by reference, by its parent folder and leaf (08 §3.3), or, for
    callers holding only a path, by its domain-relative path (08 §2.2). *)
type target = Ref of string | Rel of string | Child of destination

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
  read_only : bool;
  availability : availability option;  (** files only *)
}

(** [unnamed] counts rows whose container has no id on this client. *)
type page = { items : row list; next : string option; unnamed : int }

(** A whole-domain page, or [Walk_stale] for a cursor on another walk. *)
type listing = Listed of page | Walk_stale

type written = { size : int; mtime : float; item : row }

type fetched = {
  local_path : string;
  offset : int;
  length : int;
  item : row;  (** the version whose bytes were written *)
}

type cached = { local_path : string; item : row }
(** A change-feed op as 08 §3.6 renders it: items named by reference. *)
type feed_op =
  | Put_op of { ref_ : string; parent_ref : string; name : string; item : row option }
  | Delete_op of { ref_ : string; parent_ref : string; name : string }
  | Mkdir_op of { ref_ : string; parent_ref : string; name : string; item : row option }
  | Rmdir_op of { id : string; ref_ : string; parent_ref : string; name : string }
  | Rename_op of {
      is_dir : bool;
      id : string option;
      src_ref : string;
      src_parent_ref : string;
      ref_ : string;
      parent_ref : string;
      name : string;
      item : row option;
    }

type changes =
  | Stale
  | Changes of { cursor : string; more : bool; ops : feed_op list; unnamed : int }

type counted = { succeeded : int; failed : int }
type progress = Inactive | Active of { downloaded : int; total : int }
type resynced = Incremental of int | Full of { manifests : int; failed : int }
type trash_restored = Restored of int | Not_in_trash | Name_taken
type shared = { url : string; expires : float }

(** A transfer as [status] lists it (08 §3.3). *)
type transfer = {
  name : string;
  rel : string;
  bytes : int;
  size : int;
  seconds : float;
  rate : float;
}
[@@deriving yojson]

type status = {
  domain : string;
  read_only : bool;
  paused : bool;
  pending_uploads : int;
  pending_downloads : int;
  uploading : transfer list;
  downloading : transfer list;
  pending_bytes : int;
  subscribers : int;
  unnamed : int;
  traffic : R.traffic;
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
  | List_all : { after : string option; limit : int option } -> listing request
  | Cursor : string request
  | Changes_since : { anchor : string; limit : int option } -> changes request
  | Ensure_cached : { item : target; dest : string } -> cached request
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
      at : target;  (** a file by [Ref], or a place by [Child] *)
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
  | Share : {
      item : target;  (** the domain root when the request names nothing *)
      expires : float option;  (** seconds from now *)
      token : string option;
    }
      -> shared request
  | Share_revoke : string -> bool request  (** whether a share was there *)
  | Share_clear_cache : (int * int) request  (** objects and bytes deleted *)
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
type event = Recovered | Reset | Changed

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

(** [["item", row]], as replies nest a row. *)
val item : row -> (string * Yojson.Safe.t) list

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
