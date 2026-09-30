(** The status report's types (spec 07 §5.5): what owners, the store server and
    the supervisor answer to [stats], and what [tsync status] renders. Their
    JSON form exists only on the wire, through the derived codecs, which read
    older peers' answers leniently. *)

open Tsync_core
open Tsync_store

type traffic = {
  up_bytes : int;
  up_rate : float;
  down_bytes : int;
  down_rate : float;
}
[@@deriving yojson]

type server = {
  hostname : string;
  pid : int;
  started_at : float;
  uptime : float;
  load_avg : float option;
  role : string;
  serves : string list;
}
[@@deriving yojson]

type usage = {
  cpu_seconds : float;
  cpu_percent : float;  (** since the previous report *)
  cpu_percent_avg : float;  (** over the process's life *)
  rss_bytes : int;
  private_bytes : int;
  swapped_bytes : int;
  anonymous_bytes : int option;
  file_backed_bytes : int option;
  heap_bytes : int;
  top_heap_bytes : int;
  minor_collections : int;
  major_collections : int;
}
[@@deriving yojson]

type level = Log.level [@@deriving yojson]

type log_line = { t : float; level : level; message : string }
[@@deriving yojson]

(** A process's description of itself. *)
type self = {
  server : server;
  usage : usage;
  uplinks : Uplink.link_status list;
  traffic : traffic option;
  recent_errors : log_line list;
}
[@@deriving yojson]

type settings = {
  versioning : bool;
  symlinks : [ `Keep | `Follow | `Skip ];
  chunk_size : int;
  chunk_size_default : bool;
  cache_chunk_size : int;
  max_uploads : int;
  max_chunk_buffers : int;
  max_downloads : int;
  read_only : bool;
}
[@@deriving yojson]

type sync = {
  hold : string option;  (** the reason the journal cannot be bridged *)
  mark_age : float option;
  unapplied_entries : int;
  unapplied_reason : string option;
  parked_metadata : int;
}
[@@deriving yojson]

type cache = {
  chunks : int;
  bytes : int;
  pinned_bytes : int;
  max_cache : int option;
}
[@@deriving yojson]

type wal = {
  intent : int;
  prepared : int;
  executed : int;
  stuck : int;
  last_error : string option;
}
[@@deriving yojson]

type queues = {
  pending_files : int;
  pending_metadata : int;
  in_flight : string list;
  bytes_owed : int;
}
[@@deriving yojson]

type frontend = {
  kind : string;
  pid : int option;
  mount : string option;
  port : int option;
  open_handles : int option;
  bytes_read : int option;
  bytes_written : int option;
  unanswered : bool;
}
[@@deriving yojson]

type journal =
  | Entries of { entries : int; behind : int }
  | Counting  (** the listing did not finish within LISTING_GRACE *)
  | Unreadable of string
[@@deriving yojson]

type corrupted =
  | Not_checked of string
  | Checked of { chunks : int; truncated : bool }
[@@deriving yojson]

type reach = Reachable of { latency_ms : float } | Unreachable of string
[@@deriving yojson]

type disk = { free_bytes : int; total_bytes : int } [@@deriving yojson]

type backend = {
  name : string;
  kind : string;
  role : string;
  link : string option;
  config : (string * string) list;  (** secrets masked *)
  reach : reach;
  journal : journal;
  corrupted : corrupted;
  health : Health.state;
  disk : disk option;
  traffic : traffic option;
}
[@@deriving yojson]

type domain_body = {
  name : string;
  paused : bool;
  main_offline : bool;
  settings : settings;
  sync : sync;
  cache : cache;
  wal : wal;
  queues : queues;
  frontends : frontend list;
  backends : backend list;
}
[@@deriving yojson]

type domain = Answered of domain_body | Unanswered of string
[@@deriving yojson]

(** A process as the collector saw it; [self] is absent when it did not answer.
*)
type process = {
  role : string;
  pid : int option;
  serves : string list;
  error : string option;
  self : self option;
}
[@@deriving yojson]

type progress = {
  total : int;
  skipped : int;
  finished : int;
  handled : int;
  remaining : int;
  eta : float option;
}
[@@deriving yojson]

type job = {
  pid : int;
  kind : string;
  domain : string option;
  state : [ `Running | `Done | `Failed ];
  error : string option;
  progress : progress option;
}
[@@deriving yojson]

type warning = {
  level : level;
  message : string;
  count : int;
  first : float;
  last : float;
  pids : int list;
}
[@@deriving yojson]

(** A process's answer to [stats]. *)
type answer = { domains : domain list; self : self } [@@deriving yojson]

type machine = {
  host : string;
  domains : domain list;
  processes : process list;
  uplinks : Uplink.link_status list;  (** the governor owner's view *)
  jobs : job list;
  warnings : warning list;  (** grouped, newest first *)
}
[@@deriving yojson]
