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
type page = {
  items : row list;
  next : string option;
  unnamed : int;
  pulled_at : float option;
      (** pulled tree: when the pull the rows reflect completed (android §3.2)
      *)
  outdated : bool;  (** pulled tree: the rows are not from a fresh pull *)
}

(** android §3.2 rule 1: pull unless fresh, pull even when fresh, answer the
    mirror, or start the pull and answer the last view at once. *)
type pull = [ `Auto | `Now | `Never | `Background ]

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
  | Put_op of {
      ref_ : string;
      parent_ref : string;
      name : string;
      item : row option;
    }
  | Delete_op of { ref_ : string; parent_ref : string; name : string }
  | Mkdir_op of {
      ref_ : string;
      parent_ref : string;
      name : string;
      item : row option;
    }
  | Rmdir_op of {
      id : string;
      ref_ : string;
      parent_ref : string;
      name : string;
    }
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
  | Changes of {
      cursor : string;
      more : bool;
      ops : feed_op list;
      unnamed : int;
    }

type counted = { succeeded : int; failed : int }

type progress =
  | Inactive
  | Active of { downloaded : int; total : int }
      (** What a sync did (05 §4.7). *)

type resynced = {
  arrival : [ `Entries of int | `State of int * int ];
  changed : int;
  committed : int;
  pending : int;
}

type shared = { url : string; expires : float }

(** totp §5 [list]: never a seed. *)
type totp_row = {
  id : string;
  issuer : string;
  account : string;
  code : string;
  seconds_left : int;
}

type totp_listing = {
  rows : totp_row list;
  corrupt : string list;  (** record ids that do not open *)
  outdated : bool;  (** extensions README §4.1: answered from the last view *)
  pulled_at : float option;
}

(** totp §5.3: a seed given as its text. *)
type totp_secret = { secret : string; issuer : string; account : string }

(** totp §5 [code]: one record's current code. *)
type totp_code = { code : string; seconds_left : int }

(** totp §5 [export]: the URIs, and the ids of records that do not open. *)
type totp_exported = { uris : string list; corrupt : string list }

(** totp §5.2: refused lines by number and reason, never by content. *)
type totp_imported = {
  added : int;
  already : int;
  refused : (int * string) list;
}

(** A secret key shown once, and the key id it unlocks (vault §3, §7). *)
type secret = { secret_key : string; key_id : string }

(** vault §8.1: the colour in force, whether the user chose it, and the icon
    (PNG bytes). *)
type appearance = { color : string; color_chosen : bool; icon : string option }

(** What [vault_appearance] changes: each field kept, set or cleared. *)
type appearance_change = {
  set_color : [ `Keep | `Set of string | `Clear ];
  set_icon : [ `Keep | `Set of string | `Clear ];  (** PNG bytes *)
}

(** vault §6.2: the auto-lock policy in force, and where each of its parts comes
    from ([config] or [main]), by member name. *)
type auto_lock = { policy : Vault_lock.t; from : (string * string) list }

(** vault §6.3: a machine's entry as [vault_machines] lists it; [entry] is
    [None] for one that does not open under K. *)
type machine_entry = { name : string; enrolled : int; last_unlock : int }

type machine = { uuid : string; this : bool; entry : machine_entry option }

(** vault §7.2: the new secret key, and why re-encrypting the records stopped,
    when it did; the next unlock resumes it. *)
type rekeyed = { secret : secret; pending : string option }

(** vault §8 [status]. *)
type vault_status = {
  vault : [ `Absent | `Corrupt of string | `Locked | `Unlocked ];
  key_id : string option;
  cached : string option;  (** where K is held: [memory] *)
  slots : (string * int) list;  (** count by kind *)
  unusable : string list;  (** slots past the readers' limits *)
  copies : string list;  (** keyring copies beside it *)
  keystore_error : string option;  (** why the keystore was not used *)
  enrolled : bool;  (** this machine holds the secret key of a slot *)
  outdated : bool;  (** extensions README §4.1: answered from the last view *)
  pulled_at : float option;  (** of that view *)
  appearance : appearance option;  (** vault §8.1; none without a keyring *)
  auto_lock : auto_lock option;  (** none without a policy *)
  locked_by : [ `Idle | `Screen | `Age ] option;  (** until the next unlock *)
  new_machines : string list;  (** §6.3: names enrolled since the last list *)
  secret_key_replaced : bool;  (** §7.2: the held secret key opens no slot *)
}

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
  new_machines : string list;  (** vault §6.3, while the vault is unlocked *)
}

type _ request =
  | Ping : unit request
  | Stat : target -> row request
  | List_dir : {
      dir : target;
      after : string option;
      limit : int option;
      pull : pull;
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
      await : bool;  (** answer once the upload published or started failing *)
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
  | Revert : { item : target; version : int64 option } -> unit request
      (** [version]: a timestamp in ns; none is the newest *)
  | Full_resync : unit request
  | Sync : { full : bool } -> resynced request
  | Share : {
      item : target;  (** the domain root when the request names nothing *)
      expires : float option;  (** seconds from now *)
      token : string option;
    }
      -> shared request
  | Share_revoke : string -> bool request  (** whether a share was there *)
  | Share_preview : string -> [ `Made | `Not_made of string ] request
  | Share_clear_cache : (int * int) request  (** objects and bytes deleted *)
  | Job : { job : Jobs.t; narrate : bool } -> int request
      (** the exit status; its lines stream before the reply (07 §2.5) *)
  | Cancel : int -> bool request  (** whether that job was running *)
  | Retry : int request  (** records re-adopted *)
  | Poll : unit request
  | Wake : unit request
      (** a cycle now that pushes nothing it would not have: the listener's, for
          an entry to project (publication §4.6) *)
  | Notify_reset : int request  (** subscribers reached *)
  | Status : status request
  | Pause : bool -> bool request  (** [false] resumes; the reply is the state *)
  | Stats : string list -> Tsync_status.Status_report.answer request
  | Stop : unit request
  | Vault_init : string -> secret request  (** the passphrase as typed *)
  | Vault_unlock : {
      passphrase : string;
      secret_key : string option;
    }
      -> unit request
  | Vault_lock : [ `Lock | `Forget | `Screen ] -> unit request
      (** [`Forget] also forgets the secret key; [`Screen] is a host's report of
          a screen lock (vault §6.2) *)
  | Vault_appearance : appearance_change -> unit request  (** vault §8.1 *)
  | Vault_kit : string -> secret request
      (** vault §3.1: the passphrase as typed; the secret key it answers *)
  | Vault_machines : string option -> machine list request
      (** vault §6.3; [Some name] renames this machine's entry *)
  | Vault_rekey : {
      passphrase : string;
      new_passphrase : string option;
    }
      -> rekeyed request  (** vault §7.2 *)
  | Vault_passphrase : {
      passphrase : string;
      new_secret_key : bool;
    }
      -> secret option request
      (** the new secret key, when one was asked for *)
  | Vault_delete : string -> string option request
      (** the domain's name, to confirm; why a keystore entry was left *)
  | Vault_status : vault_status request
  | Totp_add : [ `Uri of string | `Secret of totp_secret ] -> string request
      (** a URI, or a secret with its issuer and account (totp §5.3); the new
          record's id *)
  | Totp_list : string option -> totp_listing request
  | Totp_code : string -> totp_code request  (** a record id *)
  | Totp_rename : {
      id : string;
      issuer : string option;
      account : string option;
    }
      -> unit request
  | Totp_remove : string -> unit request
  | Totp_import : string -> totp_imported request  (** the text of a file *)
  | Totp_export : string -> totp_exported request
      (** the passphrase as typed; one URI per record *)
  | Extension : {
      action : string;
      args : (string * Yojson.Safe.t) list;
    }
      -> (string * Yojson.Safe.t) list request
      (** extensions README §6: an extension's verb, its request members in and
          its reply's out, for extensions whose actions the protocol does not
          type one by one *)

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
