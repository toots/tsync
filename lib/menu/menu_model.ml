type action =
  | Nothing
  | Open_folder of string
  | Reveal of { domain : string; rel : string }
  | Set_paused of bool
  | Show_stats
  | Quit

type item = {
  label : string;
  enabled : bool;
  icon : string option;
  checked : bool option;
  indent : int;
  action : action;
  submenu : bool;
}

type entry = Separator | Item of item
type t = { icon : string; tooltip : string; entries : entry list }

let file_rows = 5
let label_max = 64

let row ?(enabled = true) ?icon ?checked ?(indent = 0) ?(submenu = false)
    ?(action = Nothing) label =
  Item { label; enabled; icon; checked; indent; action; submenu }

let join = String.concat " · "
let size = Tsync_core.Narrate.size
let rate = Tsync_core.Narrate.rate
let part f = function Some v -> [f v] | None -> []
let positive = function Some n when n > 0 -> Some n | _ -> None
let line ?indent = function [] -> [] | parts -> [row ?indent (join parts)]

let sum_known add zero values =
  match List.filter_map Fun.id values with
    | [] -> None
    | l -> Some (List.fold_left add zero l)

let duration seconds =
  if Float.is_nan seconds || seconds < 0. || seconds > 1e12 then None
  else (
    let s = int_of_float seconds in
    let parts =
      List.filter
        (fun (n, _) -> n > 0)
        [(s / 86400, "d"); (s mod 86400 / 3600, "h"); (s mod 3600 / 60, "m")]
    in
    match List.filteri (fun i _ -> i < 2) parts with
      | [] -> None
      | l ->
          Some
            (String.concat " " (List.map (fun (n, u) -> string_of_int n ^ u) l)))

let time_left ~remaining ~rate =
  match duration (remaining /. rate) with
    | Some d -> d ^ " left"
    | None -> "under a minute left"

let ellipsis text =
  if String.length text <= label_max then text
  else (
    let rec boundary i =
      if i > 0 && Char.code text.[i] land 0xC0 = 0x80 then boundary (i - 1)
      else i
    in
    let cut = boundary label_max in
    let cut =
      match String.rindex_from_opt text (cut - 1) ' ' with
        | Some i when i > label_max / 2 -> i
        | _ -> cut
    in
    String.sub text 0 cut ^ "…")

let icons =
  [
    ( "image-x-generic",
      "jpg jpeg png gif webp heic heif tif tiff bmp svg raw cr2 nef dng" );
    ("video-x-generic", "mp4 mov mkv avi webm m4v mpg mpeg wmv");
    ("audio-x-generic", "mp3 flac wav aac m4a ogg opus aiff aif");
    ("x-office-spreadsheet", "xls xlsx ods csv");
    ("x-office-presentation", "ppt pptx odp");
    ("x-office-document", "pdf doc docx odt rtf epub");
    ("package-x-generic", "zip tar gz bz2 xz zst 7z rar dmg iso");
  ]
  |> List.concat_map (fun (icon, extensions) ->
      List.map (fun e -> ("." ^ e, icon)) (String.split_on_char ' ' extensions))

let file_icon name =
  Option.value ~default:"text-x-generic"
    (List.assoc_opt (String.lowercase_ascii (Filename.extension name)) icons)

(* Lenient leaves (§2): a value of another type than stated reads as absent. *)
type count = int option

let count_of_yojson = function
  | `Int i -> Ok (Some i)
  | `Float f when Float.is_integer f -> Ok (Some (int_of_float f))
  | _ -> Ok None

type number = float option

let number_of_yojson = function
  | `Int i -> Ok (Some (float_of_int i))
  | `Float f when not (Float.is_nan f) -> Ok (Some f)
  | _ -> Ok None

type text = string option

let text_of_yojson = function `String s -> Ok (Some s) | _ -> Ok None

type flag = bool

let flag_of_yojson j = Ok (j = `Bool true)
let lenient of_yojson j = Ok (Result.to_option (of_yojson j))

let items of_yojson = function
  | `List l -> Ok (List.filter_map (fun j -> Result.to_option (of_yojson j)) l)
  | _ -> Ok []

type transfer = {
  name : string;
  rel : string;
  bytes : count; [@default None]
  size : count; [@default None]
  rate : number; [@default None]
}
[@@deriving of_yojson { strict = false }]

type traffic = {
  up_bytes : count; [@key "upBytes"] [@default None]
  up_rate : number; [@key "upRate"] [@default None]
  down_bytes : count; [@key "downBytes"] [@default None]
  down_rate : number; [@key "downRate"] [@default None]
}
[@@deriving of_yojson { strict = false }]

type status = {
  ok : flag; [@default false]
  pending_uploads : count; [@key "pendingUploads"] [@default None]
  pending_downloads : count; [@key "pendingDownloads"] [@default None]
  paused : flag; [@default false]
  uploading : transfer list; [@of_yojson items transfer_of_yojson] [@default []]
  downloading : transfer list;
      [@of_yojson items transfer_of_yojson] [@default []]
  pending_bytes : count; [@key "pendingBytes"] [@default None]
  traffic : traffic option;
      [@of_yojson lenient traffic_of_yojson] [@default None]
}
[@@deriving of_yojson { strict = false }]

let named (t : transfer) = t.name <> "" && t.rel <> ""

let status_of_json j =
  match status_of_yojson j with
    | Ok s when s.ok ->
        Some
          {
            s with
            uploading =
              List.filter_map
                (fun t ->
                  if named t then Some { t with bytes = None; rate = None }
                  else None)
                s.uploading;
            downloading = List.filter named s.downloading;
          }
    | _ -> None

let uploads s = Option.value ~default:0 s.pending_uploads
let sent s = Option.bind s.traffic (fun t -> t.up_bytes)
let send_rate s = Option.bind s.traffic (fun t -> t.up_rate)

let download_count s =
  match s.downloading with
    | [] -> Option.value ~default:0 s.pending_downloads
    | l -> List.length l

let moving s = uploads s > 0 || download_count s > 0

let activity ~uploads ~downloads =
  (if uploads > 0 then [Printf.sprintf "Uploading %d" uploads] else [])
  @ if downloads > 0 then [Printf.sprintf "Downloading %d" downloads] else []

let progress_row (t : transfer) =
  let amount =
    match (t.bytes, t.size) with
      | Some moved, Some total -> [size moved ^ " of " ^ size total]
      | Some one, None | None, Some one -> [size one]
      | None, None -> []
  in
  let speed = match t.rate with Some r when r > 0. -> [rate r] | _ -> [] in
  let left =
    match (t.bytes, t.size, t.rate) with
      | Some moved, Some total, Some r when r > 0. && total > moved ->
          [time_left ~remaining:(float_of_int (total - moved)) ~rate:r]
      | _ -> []
  in
  line ~indent:2 (amount @ speed @ left)

let file_rows_of domain transfers =
  let sorted =
    List.sort
      (fun (a : transfer) (b : transfer) -> String.compare a.name b.name)
      transfers
  in
  let shown = List.filteri (fun i _ -> i < file_rows) sorted in
  let hidden = List.length sorted - List.length shown in
  List.concat_map
    (fun (t : transfer) ->
      row ~indent:1 ~icon:(file_icon t.name)
        ~action:(Reveal { domain; rel = t.rel })
        (ellipsis t.name)
      :: progress_row t)
    shown
  @
  if hidden > 0 then [row ~indent:1 (Printf.sprintf "… and %d more" hidden)]
  else []

let domain_rows (name, status) =
  let detail, files =
    match status with
      | None -> ("not answering", [])
      | Some s ->
          ( (match
               activity ~uploads:(uploads s) ~downloads:(download_count s)
             with
              | [] -> if s.paused then "Paused" else "Idle"
              | parts -> join (parts @ if s.paused then ["paused"] else [])),
            file_rows_of name s.uploading @ file_rows_of name s.downloading )
  in
  row ~action:(Open_folder name) (name ^ " — " ^ detail) :: files

let render ?quit domains =
  let reachable = List.filter_map snd domains in
  let all_unreachable = reachable = [] in
  let all_paused =
    (not all_unreachable) && List.for_all (fun s -> s.paused) reachable
  in
  let total f = List.fold_left (fun n s -> n + f s) 0 reachable in
  let summary =
    if domains = [] then "No domains configured"
    else if all_unreachable then "Daemon not running"
    else (
      match
        activity ~uploads:(total uploads) ~downloads:(total download_count)
      with
        | [] -> if all_paused then "Paused" else "Idle"
        | parts -> join (parts @ if all_paused then ["paused"] else []))
  in
  let tooltip = "tsync — " ^ summary in
  let icon =
    if all_unreachable then "tsync-error-symbolic"
    else if all_paused then "tsync-paused-symbolic"
    else if List.exists moving reachable then "tsync-sync-symbolic"
    else "tsync-idle-symbolic"
  in
  let owed =
    positive (sum_known ( + ) 0 (List.map (fun s -> s.pending_bytes) reachable))
  and sent = sum_known ( + ) 0 (List.map sent reachable)
  and send_rate = sum_known ( +. ) 0. (List.map send_rate reachable) in
  let traffic_line =
    match (sent, owed) with
      | None, _ | Some 0, None -> []
      | Some sent, None -> [row (size sent ^ " sent")]
      | Some sent, Some owed ->
          [row (Printf.sprintf "%s sent · %s to go" (size sent) (size owed))]
  in
  let rate_line =
    match (owed, send_rate) with
      | Some owed, Some r when r > 0. ->
          [
            row (join [rate r; time_left ~remaining:(float_of_int owed) ~rate:r]);
          ]
      | _ -> []
  in
  let traffic =
    match traffic_line @ rate_line with [] -> [] | l -> Separator :: l
  in
  let entries =
    (if domains = [] then [row tooltip] else [])
    @ List.concat_map domain_rows domains
    @ traffic
    @ [
        Separator;
        row ~submenu:true ~action:Show_stats "Stats";
        row ~checked:all_paused ~enabled:(not all_unreachable)
          ~action:(Set_paused (not all_paused)) "Hold changes";
      ]
    @
      match quit with
      | Some label -> [Separator; row ~action:Quit label]
      | None -> []
  in
  { icon; tooltip; entries }

type reach = {
  reachable : flag; [@default false]
  latency_ms : number; [@key "latencyMs"] [@default None]
  error : text; [@default None]
}
[@@deriving of_yojson { strict = false }]

type journal = {
  counting : flag; [@default false]
  entries : count; [@default None]
  behind : count; [@default None]
}
[@@deriving of_yojson { strict = false }]

type corrupted = {
  checked : flag; [@default false]
  chunks : count; [@default None]
}
[@@deriving of_yojson { strict = false }]

type backend = {
  name : text; [@default None]
  role : text; [@default None]
  reach : reach option; [@of_yojson lenient reach_of_yojson] [@default None]
  journal : journal option;
      [@of_yojson lenient journal_of_yojson] [@default None]
  corrupted : corrupted option;
      [@of_yojson lenient corrupted_of_yojson] [@default None]
}
[@@deriving of_yojson { strict = false }]

type settings = {
  read_only : flag; [@key "readOnly"] [@default false]
  versioning : flag; [@default false]
}
[@@deriving of_yojson { strict = false }]

type cache = {
  chunks : count; [@default None]
  bytes : count; [@default None]
  max_cache : count; [@key "maxCache"] [@default None]
  pinned_bytes : count; [@key "pinnedBytes"] [@default None]
}
[@@deriving of_yojson { strict = false }]

type queues = {
  pending_files : count; [@key "pendingFiles"] [@default None]
  bytes_owed : count; [@key "bytesOwed"] [@default None]
}
[@@deriving of_yojson { strict = false }]

type wal = {
  intent : count; [@default None]
  prepared : count; [@default None]
  executed : count; [@default None]
  stuck : count; [@default None]
}
[@@deriving of_yojson { strict = false }]

type frontend = {
  mount : text; [@default None]
  bytes_read : count; [@key "bytesRead"] [@default None]
  bytes_written : count; [@key "bytesWritten"] [@default None]
}
[@@deriving of_yojson { strict = false }]

type domain = {
  name : string;
  unanswered : flag; [@default false]
  settings : settings option;
      [@of_yojson lenient settings_of_yojson] [@default None]
  cache : cache option; [@of_yojson lenient cache_of_yojson] [@default None]
  queues : queues option; [@of_yojson lenient queues_of_yojson] [@default None]
  wal : wal option; [@of_yojson lenient wal_of_yojson] [@default None]
  frontends : frontend list; [@of_yojson items frontend_of_yojson] [@default []]
  backends : backend list; [@of_yojson items backend_of_yojson] [@default []]
}
[@@deriving of_yojson { strict = false }]

type server = {
  hostname : text; [@default None]
  role : text; [@default None]
  pid : count; [@default None]
  uptime : number; [@key "uptimeSeconds"] [@default None]
}
[@@deriving of_yojson { strict = false }]

type usage = {
  cpu_percent : number; [@key "cpuPercentAvg"] [@default None]
  rss_bytes : count; [@key "rssBytes"] [@default None]
  heap_bytes : count; [@key "heapBytes"] [@default None]
}
[@@deriving of_yojson { strict = false }]

type self = {
  server : server option; [@of_yojson lenient server_of_yojson] [@default None]
  usage : usage option;
      [@key "process"] [@of_yojson lenient usage_of_yojson] [@default None]
  traffic : traffic option;
      [@of_yojson lenient traffic_of_yojson] [@default None]
}
[@@deriving of_yojson { strict = false }]

type stats = {
  ok : flag; [@default false]
  self : self option; [@of_yojson lenient self_of_yojson] [@default None]
  domains : domain list; [@of_yojson items domain_of_yojson] [@default []]
}
[@@deriving of_yojson { strict = false }]

let stats_of_json j =
  match stats_of_yojson j with
    | Ok (s : stats) when s.ok ->
        Some
          { s with domains = List.filter (fun d -> not d.unanswered) s.domains }
    | _ -> None

let stats_placeholder = [row "Reading…"]

let backend_row (b : backend) =
  let health =
    match b.reach with
      | None -> ""
      | Some { reachable = true; latency_ms = None; _ } -> " — reachable"
      | Some { reachable = true; latency_ms = Some ms; _ } ->
          Printf.sprintf " — reachable, %.0f ms" (Float.round ms)
      | Some { error = None | Some ""; _ } -> " — unreachable"
      | Some { error = Some e; _ } -> " — unreachable: " ^ ellipsis e
  in
  let journal =
    match b.journal with
      | Some { counting = true; _ } -> ["journal counting"]
      | Some { entries = Some entries; behind; _ } ->
          [
            (Printf.sprintf "journal %d entries" entries
            ^
              match positive behind with
              | Some n -> Printf.sprintf ", %d behind" n
              | None -> "");
          ]
      | _ -> []
  in
  let corrupt =
    match b.corrupted with
      | Some { checked = false; _ } -> ["not checked"]
      | Some { chunks = Some n; _ } when n > 0 ->
          [Printf.sprintf "%d corrupt — run tsync data-integrity" n]
      | _ -> []
  in
  row ~indent:1
    (join
       (Printf.sprintf "%s (%s)%s"
          (Option.value ~default:"?" b.name)
          (Option.value ~default:"?" b.role)
          health
       :: (journal @ corrupt)))

let domain_stats (d : domain) =
  let traits =
    match d.settings with
      | None -> []
      | Some s ->
          (if s.read_only then ["read-only"] else [])
          @ if s.versioning then ["versioned"] else []
  in
  let cache =
    match d.cache with
      | Some
          { chunks = Some chunks; bytes = Some bytes; max_cache; pinned_bytes }
        ->
          [
            Printf.sprintf "cache %d chunks · %s%s" chunks (size bytes)
              (match positive max_cache with
                | Some max -> " of " ^ size max
                | None -> "");
          ]
          @ part (fun p -> size p ^ " pinned") (positive pinned_bytes)
      | _ -> []
  in
  let queued f = Option.bind d.queues f
  and moved f = sum_known ( + ) 0 (List.map f d.frontends)
  and wal f = Option.bind d.wal f in
  let wal_pending =
    sum_known ( + ) 0
      [
        wal (fun w -> w.intent);
        wal (fun w -> w.prepared);
        wal (fun w -> w.executed);
      ]
  in
  [
    Separator;
    row (d.name ^ if traits = [] then "" else " — " ^ String.concat ", " traits);
  ]
  @ part
      (fun m -> row ~indent:1 (ellipsis m))
      (List.find_map (fun f -> f.mount) d.frontends)
  @ line ~indent:1 cache
  @ line ~indent:1
      (part
         (Printf.sprintf "queue %d files")
         (queued (fun q -> q.pending_files))
      @ part (fun b -> size b ^ " owed") (queued (fun q -> q.bytes_owed)))
  @ line ~indent:1
      (part (fun b -> "read " ^ size b) (moved (fun f -> f.bytes_read))
      @ part (fun b -> "written " ^ size b) (moved (fun f -> f.bytes_written)))
  @ line ~indent:1
      (match
         part (Printf.sprintf "%d pending") (positive wal_pending)
         @ part (Printf.sprintf "%d stuck") (positive (wal (fun w -> w.stuck)))
       with
        | [] -> []
        | first :: rest -> ("wal " ^ first) :: rest)
  @ List.map backend_row d.backends

let process_stats (s : stats) =
  let self f = Option.bind s.self f in
  let server f = Option.bind (self (fun s -> s.server)) f
  and usage f = Option.bind (self (fun s -> s.usage)) f
  and traffic f = Option.bind (self (fun s -> s.traffic)) f in
  let flow name bytes speed =
    part
      (fun b ->
        Printf.sprintf "%s %s%s" name (size b)
          (match speed with
            | Some r when r > 0. -> Printf.sprintf " (%s)" (rate r)
            | _ -> ""))
      bytes
  in
  [
    row
      (Printf.sprintf "%s — %s"
         (Option.value ~default:"?" (server (fun s -> s.hostname)))
         (Option.value ~default:"?" (server (fun s -> s.role))));
  ]
  @ part
      (fun pid ->
        row
          (join
             (Printf.sprintf "pid %d" pid
             :: part
                  (fun up ->
                    match duration up with
                      | Some d -> "up " ^ d
                      | None -> "just started")
                  (server (fun s -> s.uptime)))))
      (server (fun s -> s.pid))
  @ line
      (part (Printf.sprintf "cpu %.1f%%") (usage (fun u -> u.cpu_percent))
      @ part (fun b -> size b ^ " rss") (usage (fun u -> u.rss_bytes))
      @ part (fun b -> size b ^ " heap") (usage (fun u -> u.heap_bytes)))
  @ line
      (flow "up" (traffic (fun t -> t.up_bytes)) (traffic (fun t -> t.up_rate))
      @ flow "down"
          (traffic (fun t -> t.down_bytes))
          (traffic (fun t -> t.down_rate)))
  @ List.concat_map domain_stats s.domains

let stats = function
  | [] -> [row "No daemon answering"]
  | first :: rest ->
      process_stats first
      @ List.concat_map (fun s -> Separator :: process_stats s) rest

let action_to_yojson = function
  | Nothing -> `Assoc []
  | Open_folder domain -> `Assoc [("openFolder", `String domain)]
  | Reveal { domain; rel } ->
      `Assoc
        [("reveal", `Assoc [("domain", `String domain); ("rel", `String rel)])]
  | Set_paused paused -> `Assoc [("setPaused", `Bool paused)]
  | Show_stats -> `Assoc [("stats", `Bool true)]
  | Quit -> `Assoc [("quit", `Bool true)]

(* §7: a row's icon is not sent. *)
type wire_item = {
  label : string;
  enabled : bool;
  indent : int;
  action : action;
  checked : bool option; [@default None]
  submenu : bool; [@default false]
}
[@@deriving to_yojson]

type separator = { separator : bool } [@@deriving to_yojson]

let entry_to_json = function
  | Separator -> separator_to_yojson { separator = true }
  | Item { label; enabled; indent; action; checked; submenu; icon = _ } ->
      wire_item_to_yojson { label; enabled; indent; action; checked; submenu }

type json = Yojson.Safe.t

let json_to_yojson j = j

type wire = { icon : string; tooltip : string; entries : json list }
[@@deriving to_yojson]

let to_json (t : t) =
  wire_to_yojson
    {
      icon = t.icon;
      tooltip = t.tooltip;
      entries = List.map entry_to_json t.entries;
    }
