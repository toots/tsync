open Tsync_core
open Tsync_store

let tagged name encode decode =
  ( encode,
    fun j ->
      match decode j with
        | Some v -> Ok v
        | None -> Error (name ^ ": unexpected shape") )

let field k = function `Assoc l -> List.assoc_opt k l | _ -> None
let str k j = match field k j with Some (`String s) -> Some s | _ -> None

let int k j =
  match field k j with
    | Some (`Int i) -> Some i
    | Some (`Float f) -> Some (truncate f)
    | _ -> None

let num k j =
  match field k j with
    | Some (`Int i) -> Some (float_of_int i)
    | Some (`Float f) -> Some f
    | _ -> None

type traffic = {
  up_bytes : int; [@key "upBytes"]
  up_rate : float; [@key "upRate"]
  down_bytes : int; [@key "downBytes"]
  down_rate : float; [@key "downRate"]
}
[@@deriving yojson { strict = false }]

type server = {
  hostname : string;
  pid : int;
  started_at : float; [@key "startedAt"]
  uptime : float; [@key "uptimeSeconds"]
  load_avg : float option; [@key "loadAvg"] [@default None]
  role : string;
  serves : string list;
}
[@@deriving yojson { strict = false }]

type usage = {
  cpu_seconds : float; [@key "cpuSeconds"]
  cpu_percent : float; [@key "cpuPercent"]
  cpu_percent_avg : float; [@key "cpuPercentAvg"]
  rss_bytes : int; [@key "rssBytes"]
  private_bytes : int; [@key "privateBytes"]
  swapped_bytes : int; [@key "swappedBytes"]
  anonymous_bytes : int option; [@key "anonymousBytes"] [@default None]
  file_backed_bytes : int option; [@key "fileBackedBytes"] [@default None]
  heap_bytes : int; [@key "heapBytes"]
  top_heap_bytes : int; [@key "topHeapBytes"]
  minor_collections : int; [@key "minorCollections"]
  major_collections : int; [@key "majorCollections"]
}
[@@deriving yojson { strict = false }]

type level = Log.level = Debug | Info | Warn | Err

let level_to_yojson, level_of_yojson =
  tagged "level"
    (fun l -> `String (Log.name l))
    (function
      | `String s ->
          List.find_opt (fun l -> Log.name l = s) [Debug; Info; Warn; Err]
      | _ -> None)

type listener = {
  port : int option;
  tls : bool;
  in_flight : int; [@key "inFlight"]
  data_in_flight : int; [@key "dataInFlight"]
  bytes_read : int; [@key "bytesRead"]
  bytes_written : int; [@key "bytesWritten"]
  requests : (string * int) list;
}
[@@deriving yojson { strict = false }]

type log_line = { t : float; level : level; message : string }
[@@deriving yojson { strict = false }]

type self = {
  server : server;
  usage : usage; [@key "process"]
  uplinks : Uplink.link_status list; [@default []]
  traffic : traffic option; [@default None]
  recent_errors : log_line list; [@key "recentErrors"] [@default []]
  listener : listener option; [@default None]
}
[@@deriving yojson { strict = false }]

type symlinks = [ `Keep | `Follow | `Skip ]

let symlinks_to_yojson, symlinks_of_yojson =
  let cases = [(`Keep, "keep"); (`Follow, "follow"); (`Skip, "skip")] in
  tagged "symlinks"
    (fun v -> `String (List.assoc v cases))
    (function
      | `String s -> Option.map fst (List.find_opt (fun (_, n) -> n = s) cases)
      | _ -> None)

type settings = {
  versioning : bool;
  symlinks : symlinks;
  chunk_size : int; [@key "chunkSize"]
  chunk_size_default : bool; [@key "chunkSizeDefault"]
  cache_chunk_size : int; [@key "cacheChunkSize"]
  max_uploads : int; [@key "maxUploads"]
  max_chunk_buffers : int; [@key "maxChunkBuffers"]
  max_downloads : int; [@key "maxDownloads"]
  read_only : bool; [@key "readOnly"]
}
[@@deriving yojson { strict = false }]

type sync = {
  hold : string option; [@default None]
  mark_age : float option; [@key "markAgeSeconds"] [@default None]
  unapplied_entries : int; [@key "unappliedEntries"]
  unapplied_reason : string option; [@key "unappliedReason"] [@default None]
  parked_metadata : int; [@key "parkedMetadata"]
}
[@@deriving yojson { strict = false }]

type cache = {
  chunks : int;
  bytes : int;
  pinned_bytes : int; [@key "pinnedBytes"]
  max_cache : int option; [@key "maxCache"] [@default None]
}
[@@deriving yojson { strict = false }]

type wal = {
  intent : int;
  prepared : int;
  executed : int;
  stuck : int;
  last_error : string option; [@key "lastError"] [@default None]
}
[@@deriving yojson { strict = false }]

type queues = {
  pending_files : int; [@key "pendingFiles"]
  pending_metadata : int; [@key "pendingMetadata"]
  in_flight : string list; [@key "inFlight"]
  bytes_owed : int; [@key "bytesOwed"]
}
[@@deriving yojson { strict = false }]

type frontend = {
  kind : string; [@key "type"]
  pid : int option; [@default None]
  mount : string option; [@default None]
  port : int option; [@default None]
  open_handles : int option; [@key "openHandles"] [@default None]
  bytes_read : int option; [@key "bytesRead"] [@default None]
  bytes_written : int option; [@key "bytesWritten"] [@default None]
  shared : bool; [@default false]
  read_only : bool option; [@key "readOnly"] [@default None]
  shares : bool option; [@default None]
  unanswered : bool; [@default false]
}
[@@deriving yojson { strict = false }]

(* 07 §5.5: {entries, behind} | {counting} | {error}. *)
type journal =
  | Entries of { entries : int; behind : int }
  | Counting
  | Unreadable of string

let journal_to_yojson, journal_of_yojson =
  tagged "journal"
    (function
      | Entries e ->
          `Assoc [("entries", `Int e.entries); ("behind", `Int e.behind)]
      | Counting -> `Assoc [("counting", `Bool true)]
      | Unreadable e -> `Assoc [("error", `String e)])
    (fun j ->
      match (field "counting" j, str "error" j, int "entries" j) with
        | Some (`Bool true), _, _ -> Some Counting
        | _, Some e, _ -> Some (Unreadable e)
        | _, _, Some n ->
            Some
              (Entries
                 {
                   entries = n;
                   behind = Option.value ~default:0 (int "behind" j);
                 })
        | _ -> None)

type corrupted =
  | Not_checked of string
  | Checked of { chunks : int; truncated : bool }

let corrupted_to_yojson, corrupted_of_yojson =
  tagged "corrupted"
    (function
      | Not_checked why ->
          `Assoc [("checked", `Bool false); ("reason", `String why)]
      | Checked c ->
          `Assoc
            [
              ("checked", `Bool true);
              ("chunks", `Int c.chunks);
              ("truncated", `Bool c.truncated);
            ])
    (fun j ->
      match field "checked" j with
        | Some (`Bool true) ->
            Some
              (Checked
                 {
                   chunks = Option.value ~default:0 (int "chunks" j);
                   truncated = field "truncated" j = Some (`Bool true);
                 })
        | _ -> Some (Not_checked (Option.value ~default:"" (str "reason" j))))

type reach = Reachable of { latency_ms : float } | Unreachable of string

let reach_to_yojson, reach_of_yojson =
  tagged "reach"
    (function
      | Reachable r ->
          `Assoc [("reachable", `Bool true); ("latencyMs", `Float r.latency_ms)]
      | Unreachable e ->
          `Assoc [("reachable", `Bool false); ("error", `String e)])
    (fun j ->
      match field "reachable" j with
        | Some (`Bool true) ->
            Some
              (Reachable
                 { latency_ms = Option.value ~default:0. (num "latencyMs" j) })
        | _ -> Some (Unreachable (Option.value ~default:"" (str "error" j))))

type disk = {
  free_bytes : int; [@key "freeBytes"]
  total_bytes : int; [@key "totalBytes"]
}
[@@deriving yojson { strict = false }]

type copy_job = {
  job : string;
  path : string option; [@default None]
  size : int option; [@default None]
  chunks : int;
  checked : int;
  sent : int; [@key "sentBytes"]
  elapsed : float; [@key "elapsedSeconds"]
  eta : float option; [@key "etaSeconds"] [@default None]
}
[@@deriving yojson { strict = false }]

type copies = {
  owed : int;
  parked : int;
  rate : float; [@key "jobsPerSec"]
  current : copy_job option; [@default None]
}
[@@deriving yojson { strict = false }]

type config = (string * string) list

let config_to_yojson, config_of_yojson =
  tagged "config"
    (fun l -> `Assoc (List.map (fun (k, v) -> (k, `String v)) l))
    (function
      | `Assoc l ->
          Some
            (List.map
               (fun (k, v) ->
                 ( k,
                   match v with `String s -> s | v -> Yojson.Safe.to_string v ))
               l)
      | _ -> None)

type backend = {
  name : string;
  kind : string; [@key "type"]
  role : string;
  link : string option; [@default None]
  config : config; [@default []]
  reach : reach;
  journal : journal;
  corrupted : corrupted;
  health : Health.state;
  disk : disk option; [@default None]
  copies : copies option; [@default None]
  traffic : traffic option; [@default None]
}
[@@deriving yojson { strict = false }]

type domain_body = {
  name : string;
  paused : bool;
  main_offline : bool; [@key "mainOffline"] [@default false]
  settings : settings;
  sync : sync;
  cache : cache;
  wal : wal;
  queues : queues;
  frontends : frontend list; [@default []]
  backends : backend list; [@default []]
}
[@@deriving yojson { strict = false }]

(* 07 §5.5: a domain no process answered for is a stub {name, unanswered}. *)
type domain = Answered of domain_body | Unanswered of string

let domain_to_yojson, domain_of_yojson =
  ( (function
    | Answered b -> domain_body_to_yojson b
    | Unanswered n -> `Assoc [("name", `String n); ("unanswered", `Bool true)]),
    fun j ->
      match (field "unanswered" j, str "name" j) with
        | Some (`Bool true), Some n -> Ok (Unanswered n)
        | _ -> Result.map (fun b -> Answered b) (domain_body_of_yojson j) )

type process = {
  role : string;
  pid : int option; [@default None]
  serves : string list; [@default []]
  error : string option; [@default None]
  self : self option; [@default None]
}
[@@deriving yojson { strict = false }]

type progress = {
  total : int; [@default 0]
  skipped : int; [@default 0]
  finished : int; [@key "done"] [@default 0]
  handled : int; [@default 0]
  remaining : int; [@default 0]
  eta : float option; [@key "etaSeconds"] [@default None]
}
[@@deriving yojson { strict = false }]

type job_state = [ `Running | `Done | `Failed ]

let job_state_to_yojson, job_state_of_yojson =
  let cases = [(`Running, "running"); (`Done, "done"); (`Failed, "failed")] in
  tagged "state"
    (fun v -> `String (List.assoc v cases))
    (function
      | `String s -> Option.map fst (List.find_opt (fun (_, n) -> n = s) cases)
      | _ -> None)

type job = {
  pid : int;
  kind : string;
  domain : string option; [@default None]
  state : job_state;
  error : string option; [@default None]
  progress : progress option; [@default None]
}
[@@deriving yojson { strict = false }]

type warning = {
  level : level;
  message : string;
  count : int;
  first : float;
  last : float;
  pids : int list;
}
[@@deriving yojson { strict = false }]

type presented = { domain : string; frontend : frontend }
[@@deriving yojson { strict = false }]

type answer = {
  domains : domain list; [@default []]
  presented : presented list; [@default []]
  self : self;
}
[@@deriving yojson { strict = false }]

let answered answers =
  List.concat_map
    (fun (name, a) ->
      match a with Ok a -> a.domains | Error _ -> [Unanswered name])
    answers

let with_presented domains presented =
  List.map
    (function
      | Answered body ->
          Answered
            {
              body with
              frontends =
                body.frontends
                @ List.filter_map
                    (fun p ->
                      if p.domain = body.name then Some p.frontend else None)
                    presented;
            }
      | Unanswered _ as d -> d)
    domains

type machine = {
  host : string;
  domains : domain list;
  processes : process list;
  uplinks : Uplink.link_status list; [@default []]
  jobs : job list; [@default []]
  warnings : warning list; [@default []]
}
[@@deriving yojson { strict = false }]
