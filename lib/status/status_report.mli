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

(** An http-proxy listener's counters (frontends/http-proxy §A12): bytes are the
    server's own, once per request; [requests] is one tally per kind. *)
type listener = {
  port : int option;
  tls : bool;
  in_flight : int;
  data_in_flight : int;
  shares_in_flight : int;  (** share responses open, of [shares_max] *)
  shares_max : int;
  bytes_read : int;
  bytes_written : int;
  requests : (string * int) list;
}
[@@deriving yojson]

(** A process's description of itself. *)
type self = {
  server : server;
  usage : usage;
  uplinks : Uplink.link_status list;
  traffic : traffic option;
  recent_errors : log_line list;
  listener : listener option;  (** an http-proxy store server's own figures *)
}
[@@deriving yojson]

(** Where each domain-wide setting in force comes from (05 §2.1): "config",
    "main" or "default". *)
type sources = (string * string) list

(** vault §6.2, in force. *)
type vault_lock = Vault_lock.t

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
  project_lease : float;
  project_quarantine : float;
  project_settle : float;
  max_entry_commands : int;
  batch_delay : float;
  project_width : int;
  projector : string option;
  extensions : string list;  (** 05 §2.1 rule 5: in force *)
  vault_lock : vault_lock option;  (** rule 7: in force, none without one *)
  domain_wide : sources;
}
[@@deriving yojson]

(** An entry the client cannot follow, and why. *)
type cannot_follow = { entry : int; reason : string } [@@deriving yojson]

(** The cycle's status (03 §3.4): [in_flight] is the number of the entry being
    created. *)
type sync = {
  position : int option;
  pending : int;
  in_flight : int option;
  tree_head : int option;
  cannot_follow : cannot_follow option;
  failing : string option;
}
[@@deriving yojson]

type cache = {
  chunks : int;
  bytes : int;
  pinned_bytes : int;
  max_cache : int option;
}
[@@deriving yojson]

type queues = {
  pending_files : int;
  parked : int;
  in_flight : string list;
  bytes_owed : int;
  last_error : string option;
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
  shared : bool;  (** one listener serving several domains *)
  read_only : bool option;
  shares : bool option;  (** serves share links *)
  unanswered : bool;
  unpresented : int option;
  untaken : int option;
  pending_folders : int option;
}
[@@deriving yojson]

type corrupted =
  | Not_checked of string
  | Checked of { chunks : int; truncated : bool }
[@@deriving yojson]

type reach = Reachable of { latency_ms : float } | Unreachable of string
[@@deriving yojson]

type disk = { free_bytes : int; total_bytes : int } [@@deriving yojson]

(** The job a copy log is running: a file's manifest names [chunks], of which
    [checked] are known to be on the copy or sent; [eta] is from its own pace.
*)
type copy_job = {
  job : string;
  path : string option;
  size : int option;
  chunks : int;
  checked : int;
  sent : int;
  elapsed : float;
  eta : float option;
}
[@@deriving yojson]

(** A copy member's deferred copies: jobs owed and parked, the rate jobs
    complete at, and the job running now. *)
type copies = {
  owed : int;
  parked : int;
  rate : float;
  current : copy_job option;
}
[@@deriving yojson]

type backend = {
  name : string;
  kind : string;
  role : string;
  link : string option;
  config : (string * string) list;  (** secrets masked *)
  reach : reach;
  corrupted : corrupted;
  health : Health.state;
  disk : disk option;
  copies : copies option;
  traffic : traffic option;
}
[@@deriving yojson]

type domain_body = {
  name : string;
  paused : bool;
  main_offline : bool;
  settings : settings;
  sync : sync;
  set_aside : int;
  cache : cache;
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
  step : string option;  (** what the job is doing now, as its progress says *)
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

(** A frontend another process presents for a domain: a shared listener
    (frontends/http-proxy §A10). *)
type presented = { domain : string; frontend : frontend } [@@deriving yojson]

(** A process's answer to [stats]: the domains it owns, and the frontends it
    presents for domains others own. *)
type answer = { domains : domain list; presented : presented list; self : self }
[@@deriving yojson]

(** The sections owners answered with, and [Unanswered] for each domain whose
    owner did not answer. *)
val answered : (string * (answer, string) result) list -> domain list

(** Each presented frontend appended to its domain's section; one for an
    unanswered domain is dropped. *)
val with_presented : domain list -> presented list -> domain list

type machine = {
  host : string;
  domains : domain list;
  processes : process list;
  uplinks : Uplink.link_status list;  (** the governor owner's view *)
  jobs : job list;
  warnings : warning list;  (** grouped, newest first *)
}
[@@deriving yojson]
