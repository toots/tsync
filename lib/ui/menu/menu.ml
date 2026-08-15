type transfer = {
  name : string;
  rel : string;
  moved : int64 option;
  total : int64 option;
  rate : float option;
}

type status = {
  name : string;
  uploads : int option;
  downloads : int option;
  paused : bool option;
  uploading : transfer list;
  downloading : transfer list;
  pending_bytes : int64 option;
  bytes_uploaded : int64 option;
  upload_rate : float option;
}

let unreachable name =
  {
    name;
    uploads = None;
    downloads = None;
    paused = None;
    uploading = [];
    downloading = [];
    pending_bytes = None;
    bytes_uploaded = None;
    upload_rate = None;
  }

(* What the submenu draws, which is `tsync status' with most of it left out: the
   figures someone opens a tray menu to see, rather than the ones they would run
   the command for. *)
type backend_stats = {
  backend_name : string;
  role : string;
  backend_reachable : bool;
  latency_ms : float option;
  backend_error : string option;
  journal_entries : int option;
  journal_behind : int option;
  corrupted_chunks : int option;
  corruption : [ `Checked | `Unchecked | `Failed ];
}

type domain_stats = {
  domain_name : string;
  mount_point : string option;
  read_only : bool;
  versioning : bool;
  cache_chunks : int option;
  cache_bytes : int64 option;
  cache_max : int64 option;
  in_uploads : int option;
  in_downloads : int option;
  staged : int option;
  bytes_read : int64 option;
  bytes_written : int64 option;
  wal_pending : int option;
  wal_stuck : int option;
  backends : backend_stats list;
}

type stats = {
  host : string;
  frontend : string;
  pid : int;
  uptime : float;
  cpu_percent : float;
  rss : int64;
  heap : int64;
  uploaded : int64;
  up_rate : float;
  downloaded : int64;
  down_rate : float;
  domain_stats : domain_stats list;
}

(* A domain and a path under it, never an absolute one: where a domain's folder
   actually is differs per client -- on macOS only the app can ask the File
   Provider -- so resolving it is the renderer's job. *)
type target = { domain : string; rel : string }

type action =
  | Nothing
  | Open_folder of string
  | Reveal_file of target
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
type menu = { icon : string; tooltip : string; entries : entry list }

(* The queue runs a handful at a time, but a wide fan-out must not push the rest
   of the menu off the screen. *)
let max_uploading_shown = 5
let reachable s = s.uploads <> None

(* [downloads] counts chunk fetches in flight, which is not what the rows under
   this count: one file is many chunks, and several files can share one fetch.
   Where there are rows, they are what the number has to agree with. *)
let download_count s =
  match s.downloading with
    | [] -> s.downloads
    | files -> Some (List.length files)

(* Counted off the rows wherever there are rows: [downloads] is chunk fetches at
   the instant of asking, so a sequential read that is plainly moving reads zero
   between one fetch and the next -- and the icon would blink to idle under a row
   saying otherwise. Below the reporting threshold there are no rows, and the
   fetch count is what is left to notice it by. *)
let is_transferring s =
  Option.value s.uploads ~default:0
  + Option.value (download_count s) ~default:0
  + Option.value s.downloads ~default:0
  > 0

let all_unreachable statuses =
  List.for_all (fun s -> not (reachable s)) statuses

let any_unreachable statuses = List.exists (fun s -> not (reachable s)) statuses

let all_paused statuses =
  statuses <> [] && List.for_all (fun s -> s.paused = Some true) statuses

let sum_opt f statuses =
  List.fold_left
    (fun acc s -> match f s with Some v -> acc + v | None -> acc)
    0 statuses

(* The domains' own bytes are summed; the rate and the running total are the
   daemon's, one per process, so they are read once rather than added up. *)
let pending_bytes statuses =
  List.fold_left
    (fun acc s ->
      match s.pending_bytes with Some v -> Int64.add acc v | None -> acc)
    0L statuses

let first_some f statuses = List.find_map f statuses
let bytes_uploaded statuses = first_some (fun s -> s.bytes_uploaded) statuses
let upload_rate statuses = first_some (fun s -> s.upload_rate) statuses

(* The same formatter `tsync status' prints with, so one byte count does not read
   two ways depending on where you looked. *)
let human_bytes n = Metrics.human_bytes (Int64.to_int n)

(* Day, hour and minute, the two largest non-zero of them, truncated. Anything
   under a minute has no honest answer, and a made-up one is worse than none. *)
let eta seconds =
  if Float.is_nan seconds || seconds < 0. || seconds > 1e12 then None
  else (
    let total = int_of_float seconds in
    let parts =
      [
        (total / 86400, "d");
        (total mod 86400 / 3600, "h");
        (total mod 3600 / 60, "m");
      ]
    in
    let shown =
      List.filteri (fun i _ -> i < 2) (List.filter (fun (n, _) -> n > 0) parts)
    in
    match shown with
      | [] -> None
      | l ->
          Some
            (String.concat " "
               (List.map (fun (n, u) -> Printf.sprintf "%d%s" n u) l)))

let summary statuses =
  if statuses = [] then "No domains configured"
  else if any_unreachable statuses && all_unreachable statuses then
    "Daemon not running"
  else (
    let uploads = sum_opt (fun s -> s.uploads) statuses in
    let downloads = sum_opt download_count statuses in
    if uploads = 0 && downloads = 0 then
      if all_paused statuses then "Paused" else "Idle"
    else (
      let parts =
        (if uploads > 0 then [Printf.sprintf "Uploading %d" uploads] else [])
        @ (if downloads > 0 then [Printf.sprintf "Downloading %d" downloads]
           else [])
        @ if all_paused statuses then ["paused"] else []
      in
      String.concat " · " parts))

let detail s =
  match (s.uploads, download_count s) with
    | None, _ | _, None -> "not answering"
    | Some 0, Some 0 -> if s.paused = Some true then "Paused" else "Idle"
    | Some up, Some 0 -> Printf.sprintf "Uploading %d" up
    | Some 0, Some down -> Printf.sprintf "Downloading %d" down
    | Some up, Some down ->
        Printf.sprintf "Uploading %d · Downloading %d" up down

(* "223.2 MB sent · 12.8 GB to go", or just what has been sent once the queue is
   empty. *)
let traffic_line statuses =
  let pending = pending_bytes statuses in
  match bytes_uploaded statuses with
    (* Nothing sent and nothing owed is a row saying zero, which the rows above
       it already imply. It earns its place once either number is real. *)
    | (None | Some 0L) when pending <= 0L -> None
    | None -> None
    | Some sent ->
        let head = Printf.sprintf "%s sent" (human_bytes sent) in
        if pending <= 0L then Some head
        else Some (Printf.sprintf "%s · %s to go" head (human_bytes pending))

(* "1.6 MB/s · 2h 13m left". No rate yet means no estimate. *)
let rate_line statuses =
  let pending = pending_bytes statuses in
  match upload_rate statuses with
    | Some rate when pending > 0L && rate > 0. ->
        let speed = Printf.sprintf "%s/s" (human_bytes (Int64.of_float rate)) in
        let seconds = Int64.to_float pending /. rate in
        Some
          (match eta seconds with
            | Some left -> Printf.sprintf "%s · %s left" speed left
            | None -> Printf.sprintf "%s · under a minute left" speed)
    | _ -> None

(* Priority is macOS's: what is broken outranks what is deliberate, which
   outranks what is merely busy. An empty domain list lands on the warning too,
   which is right -- nothing configured is nothing working.

   Our own four, shipped into hicolor from [assets/tray]. They used to be
   borrowed from the icon theme, which meant they were chosen for being present
   rather than for reading as one set, and being present was not portable: the
   spec's [network-transmit-receive] is in neither Breeze nor a current Adwaita.

   The [-symbolic] suffix is load-bearing on Linux. It is what makes a panel
   recolour the icon to its own foreground instead of drawing it in the colour
   the file names, which is the difference between visible and invisible on a
   dark panel. macOS ignores the name and maps it to an SF Symbol. *)
let icon_name statuses =
  if all_unreachable statuses then "tsync-error-symbolic"
  else if all_paused statuses then "tsync-paused-symbolic"
  else if List.exists is_transferring statuses then "tsync-sync-symbolic"
  else "tsync-idle-symbolic"

(* The generic names only, never [image-jpeg]: a specific name a theme happens
   not to carry draws nothing at all, and without a toolkit there is no way to
   ask a theme what it has. Every name below is in the icon naming spec. *)
let file_icon name =
  match String.lowercase_ascii (Filename.extension name) with
    | ".jpg" | ".jpeg" | ".png" | ".gif" | ".webp" | ".heic" | ".heif" | ".tif"
    | ".tiff" | ".bmp" | ".svg" | ".raw" | ".cr2" | ".nef" | ".dng" ->
        "image-x-generic"
    | ".mp4" | ".mov" | ".mkv" | ".avi" | ".webm" | ".m4v" | ".mpg" | ".mpeg"
    | ".wmv" ->
        "video-x-generic"
    | ".mp3" | ".flac" | ".wav" | ".aac" | ".m4a" | ".ogg" | ".opus" | ".aiff"
    | ".aif" ->
        "audio-x-generic"
    | ".xls" | ".xlsx" | ".ods" | ".csv" -> "x-office-spreadsheet"
    | ".ppt" | ".pptx" | ".odp" -> "x-office-presentation"
    | ".pdf" | ".doc" | ".docx" | ".odt" | ".rtf" | ".epub" ->
        "x-office-document"
    | ".zip" | ".tar" | ".gz" | ".bz2" | ".xz" | ".zst" | ".7z" | ".rar"
    | ".dmg" | ".iso" ->
        "package-x-generic"
    | _ -> "text-x-generic"

(* Up to three, newest first: enough to see that something is wrong and roughly
   what, which is all a menu row can carry. The rest is what `tsync status' is
   for. *)
(* A mount path or a backend's complaint can run to any length, and a menu that
   wide is one that covers the screen it is meant to sit beside. Cut at the last
   space before the limit so a word is not split, and never inside a UTF-8
   character -- a continuation byte on its own is a label the panel may refuse. *)
let max_row_width = 64

let ellipsis text =
  if String.length text <= max_row_width then text
  else (
    let cut = ref max_row_width in
    while !cut > 0 && Char.code text.[!cut] land 0xC0 = 0x80 do
      decr cut
    done;
    match String.rindex_from_opt text (!cut - 1) ' ' with
      | Some space when space > max_row_width / 2 ->
          String.sub text 0 space ^ "…"
      | _ -> String.sub text 0 !cut ^ "…")

(* Informational rows stay enabled. Disabling them would be the honest thing if
   "enabled" meant "does something", but every menu draws a disabled row grey,
   which is how information ends up looking like a broken command. *)
let info ?icon ?(indent = 0) ?(action = Nothing) ?(submenu = false) label =
  Item { label; enabled = true; icon; checked = None; indent; action; submenu }

(* An uptime, not a countdown, so [eta]'s "nothing honest to say" under a minute
   becomes the thing there is to say. *)
let uptime_text seconds =
  match eta seconds with Some t -> "up " ^ t | None -> "just started"

let backend_row (b : backend_stats) =
  let health =
    if b.backend_reachable then (
      match b.latency_ms with
        | Some ms -> Printf.sprintf "reachable, %.0f ms" ms
        | None -> "reachable")
    else (
      (* Only the message is cut. Trimming the whole row instead would drop the
         journal figures off the end, which are the part that says how far
         behind this backend now is. *)
        match b.backend_error with
        | Some why -> "unreachable: " ^ ellipsis why
        | None -> "unreachable")
  in
  let journal =
    match (b.journal_entries, b.journal_behind) with
      | None, _ -> []
      (* Behind is the number worth saying; level is the normal state and says
         nothing. *)
      | Some n, Some behind when behind > 0 ->
          [Printf.sprintf "journal %d entries, %d behind" n behind]
      | Some n, _ -> [Printf.sprintf "journal %d entries" n]
  in
  let corrupted =
    match (b.corruption, b.corrupted_chunks) with
      | `Failed, _ -> ["corruption check failed"]
      | `Unchecked, _ -> ["not checked"]
      | `Checked, Some n when n > 0 ->
          [Printf.sprintf "%d corrupt — run tsync repair" n]
      | `Checked, _ -> []
  in
  info ~indent:1
    (String.concat " · "
       (Printf.sprintf "%s (%s) — %s" b.backend_name b.role health
       :: (journal @ corrupted)))

(* A row per figure that has one, skipped where the daemon did not report it:
   half a row is worse than none, and a frontend that keeps no byte counters
   should not be made to look like one that read nothing. *)
let optional_row indent = function
  | [] -> []
  | parts -> [info ~indent (String.concat " · " parts)]

let cache_row (d : domain_stats) =
  match (d.cache_chunks, d.cache_bytes) with
    | Some chunks, Some bytes ->
        let of_max =
          match d.cache_max with
            | Some max when max > 0L -> " of " ^ human_bytes max
            | _ -> ""
        in
        [
          info ~indent:1
            (Printf.sprintf "cache %d chunks · %s%s" chunks (human_bytes bytes)
               of_max);
        ]
    | _ -> []

let queue_row (d : domain_stats) =
  optional_row 1
    (List.filter_map Fun.id
       [
         Option.map (Printf.sprintf "%d uploading") d.in_uploads;
         Option.map (Printf.sprintf "%d downloading") d.in_downloads;
         Option.map (Printf.sprintf "%d staged") d.staged;
       ])

let io_row (d : domain_stats) =
  optional_row 1
    (List.filter_map Fun.id
       [
         Option.map (fun n -> "read " ^ human_bytes n) d.bytes_read;
         Option.map (fun n -> "written " ^ human_bytes n) d.bytes_written;
       ])

(* Only when there is something owed. An empty journal is the normal state, and
   a row saying so every time is one more line between the reader and the one
   that matters. *)
let wal_row (d : domain_stats) =
  optional_row 1
    (List.filter_map Fun.id
       [
         (match d.wal_pending with
           | Some n when n > 0 -> Some (Printf.sprintf "wal %d pending" n)
           | _ -> None);
         (match d.wal_stuck with
           | Some n when n > 0 -> Some (Printf.sprintf "%d stuck" n)
           | _ -> None);
       ])

let domain_section (d : domain_stats) =
  let flags =
    (if d.read_only then ["read-only"] else [])
    @ if d.versioning then ["versioned"] else []
  in
  let head =
    match flags with
      | [] -> d.domain_name
      | fs -> Printf.sprintf "%s — %s" d.domain_name (String.concat ", " fs)
  in
  info head
  ::
    (match d.mount_point with
    | Some m -> [info ~indent:1 (ellipsis m)]
    | None -> [])
  @ cache_row d @ queue_row d @ io_row d @ wal_row d
  @ List.map backend_row d.backends

(* "12.49 GB (1.6 MB/s)", or the total alone while nothing is moving: a rate of
   zero is the normal state, and repeating it on every row is noise. *)
let with_rate total rate =
  if rate > 0. then
    Printf.sprintf "%s (%s/s)" (human_bytes total)
      (human_bytes (Int64.of_float rate))
  else human_bytes total

(* One section per answering daemon. Linux gives each domain its own process, so
   that is usually one section per domain, each with its own pid and its own
   share of the machine. *)
let daemon_section (s : stats) =
  [
    info (Printf.sprintf "%s — %s" s.host s.frontend);
    info (Printf.sprintf "pid %d · %s" s.pid (uptime_text s.uptime));
    info
      (Printf.sprintf "cpu %.1f%% · %s rss · %s heap" s.cpu_percent
         (human_bytes s.rss) (human_bytes s.heap));
    info
      (Printf.sprintf "up %s · down %s"
         (with_rate s.uploaded s.up_rate)
         (with_rate s.downloaded s.down_rate));
  ]
  @ List.concat_map (fun d -> Separator :: domain_section d) s.domain_stats

(* What the submenu holds until the first answer arrives. A submenu with nothing
   in it is one some panels decline to open at all, so it is never empty. *)
let stats_placeholder = [info "Reading…"]

let stats_entries = function
  | [] -> [info "No daemon answering"]
  | all ->
      List.concat
        (List.mapi
           (fun i s ->
             if i = 0 then daemon_section s else Separator :: daemon_section s)
           all)

(* One shape for both directions, so a download row and an upload row cannot
   drift apart. Which downloads are worth a row was settled by the daemon, which
   is why nothing here has to weigh them. *)
(* "752 MB of 14.5 GB · 1.6 MB/s · 2h 23m left", dropping whatever the daemon
   did not report. Under the name rather than beside it: a menu is as wide as
   its widest row, and file names are long enough already.

   The estimate reads the whole file as what is left to fetch, so a file part of
   which was already cached finishes sooner than it says. Over-stating what
   remains beats a number that runs out while the transfer is still going. *)
let progress_line (u : transfer) =
  let parts =
    (match (u.moved, u.total) with
      | Some moved, Some total ->
          [Printf.sprintf "%s of %s" (human_bytes moved) (human_bytes total)]
      | Some moved, None -> [human_bytes moved]
      (* An upload knows how big it is and not how far along, which is still
         worth saying: it is the number that answers what this will cost. *)
      | None, Some total -> [human_bytes total]
      | None, None -> [])
    @ (match u.rate with
      | Some rate when rate > 0. ->
          [Printf.sprintf "%s/s" (human_bytes (Int64.of_float rate))]
      | _ -> [])
    @
      match (u.moved, u.total, u.rate) with
      | Some moved, Some total, Some rate when rate > 0. && total > moved -> (
          match eta (Int64.to_float (Int64.sub total moved) /. rate) with
            | Some left -> [left ^ " left"]
            | None -> ["under a minute left"])
      | _ -> []
  in
  match parts with
    | [] -> []
    | parts -> [info (String.concat " · " parts) ~indent:2]

let file_rows s transfers =
  let shown =
    List.sort (fun (a : transfer) b -> compare a.name b.name) transfers
  in
  let rows =
    List.filteri (fun i _ -> i < max_uploading_shown) shown
    |> List.concat_map (fun (u : transfer) ->
        info (ellipsis u.name) ~icon:(file_icon u.name) ~indent:1
          ~action:(Reveal_file { domain = s.name; rel = u.rel })
        :: progress_line u)
  in
  let hidden = List.length transfers - max_uploading_shown in
  rows
  @
  if hidden > 0 then [info (Printf.sprintf "… and %d more" hidden) ~indent:1]
  else []

let render ?(quit_label = "Quit tsync tray") statuses =
  (* Only when there is no domain row to say it instead. A domain row carries
     the same state, names which domain it is about, and opens the folder; the
     summary across all of them is in the tooltip. With nothing configured there
     are no rows at all, and this is the whole message. *)
  let header =
    if statuses = [] then
      [info (Printf.sprintf "tsync — %s" (summary statuses))]
    else []
  in
  let domain s =
    let row =
      info
        (Printf.sprintf "%s — %s" s.name (detail s))
        ~action:(Open_folder s.name)
    in
    (row :: file_rows s s.uploading) @ file_rows s s.downloading
  in
  (* No separator ahead of the domains any more: with the header gone they are
     the first thing in the menu, and a rule above the first row draws as a gap
     at the top. *)
  let domains = List.concat_map domain statuses in
  let traffic =
    match traffic_line statuses with
      | None -> []
      | Some line -> (
          (Separator :: [info line])
          @ match rate_line statuses with Some r -> [info r] | None -> [])
  in
  let pause =
    Item
      {
        label = "Pause uploads";
        enabled = not (all_unreachable statuses);
        icon = None;
        checked = Some (all_paused statuses);
        indent = 0;
        (* Never set from here: the next poll reads back what the daemon did, so
           the checkmark shows the daemon's answer rather than our request. *)
        action = Set_paused (not (all_paused statuses));
        submenu = false;
      }
  in
  (* A submenu rather than a row: what the panel draws next to the icon is the
     only window we get, and the rest of the report is more than the menu itself
     has room for. Its rows are filled in when it opens -- a [stats] call
     reaches every backend, which is a round trip nobody asked for every three
     seconds. Until then it says so. *)
  let stats = info "Stats" ~action:Show_stats ~submenu:true in
  (* The daemon is a service this menu does not own, on either platform: it
     outlives us under systemd or launchd, and someone hiding an icon must not
     find their files stopped syncing. So the label names the icon rather than
     tsync -- what that icon is called is the caller's to say. *)
  let quit =
    Item
      {
        label = quit_label;
        enabled = true;
        icon = None;
        checked = None;
        indent = 0;
        action = Quit;
        submenu = false;
      }
  in
  {
    icon = icon_name statuses;
    tooltip = Printf.sprintf "tsync — %s" (summary statuses);
    entries =
      ((header @ domains) @ traffic)
      @ [Separator; stats; pause; Separator; quit];
  }

let action_json = function
  | Nothing -> `Assoc []
  | Open_folder domain -> `Assoc [("openFolder", `String domain)]
  | Reveal_file { domain; rel } ->
      `Assoc
        [("reveal", `Assoc [("domain", `String domain); ("rel", `String rel)])]
  | Set_paused paused -> `Assoc [("setPaused", `Bool paused)]
  | Show_stats -> `Assoc [("stats", `Bool true)]
  | Quit -> `Assoc [("quit", `Bool true)]

(* Only what a row actually carries, so a renderer can tell "no icon" from an
   icon it failed to read. *)
let entry_json = function
  | Separator -> `Assoc [("separator", `Bool true)]
  | Item i ->
      `Assoc
        ([
           ("label", `String i.label);
           ("enabled", `Bool i.enabled);
           ("indent", `Int i.indent);
           ("action", action_json i.action);
         ]
        (* [icon] is not here: it names a freedesktop icon for a panel to look
           up, and the only reader of this JSON is a menu bar that has no such
           icons and derives its own from the file's path. *)
        @ (match i.checked with
          | Some on -> [("checked", `Bool on)]
          | None -> [])
        @ if i.submenu then [("submenu", `Bool true)] else [])

let entries_to_json entries = `List (List.map entry_json entries)

let to_json m =
  `Assoc
    [
      ("icon", `String m.icon);
      ("tooltip", `String m.tooltip);
      ("rows", entries_to_json m.entries);
      (* A submenu's rows are fetched when it opens, so a client needs something
         to put in it until they land. Carried rather than spelled by the client
         so both platforms say the same thing. *)
      ("submenuPlaceholder", entries_to_json stats_placeholder);
    ]

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let int_field json name =
  match member name json with Some (`Int n) -> Some n | _ -> None

let int64_field json name =
  match member name json with
    | Some (`Int n) -> Some (Int64.of_int n)
    | _ -> None

let float_field json name =
  match member name json with
    | Some (`Float f) -> Some f
    | Some (`Int n) -> Some (float_of_int n)
    | _ -> None

let bool_field json name =
  match member name json with Some (`Bool b) -> Some b | _ -> None

let string_field json name =
  match member name json with
    | Some (`String s) when s <> "" -> Some s
    | _ -> None

let transfers_of json field =
  match member field json with
    | Some (`List items) ->
        List.filter_map
          (fun item ->
            match (string_field item "name", string_field item "rel") with
              | Some name, Some rel ->
                  Some
                    {
                      name;
                      rel;
                      moved = int64_field item "bytes";
                      total = int64_field item "size";
                      rate = float_field item "rate";
                    }
              | _ -> None)
          items
    | _ -> []

let of_status_json ~name json =
  match bool_field json "ok" with
    | Some false | None -> unreachable name
    | Some true ->
        {
          name;
          uploads =
            Some (Option.value (int_field json "pendingUploads") ~default:0);
          downloads =
            Some (Option.value (int_field json "pendingDownloads") ~default:0);
          paused = Some (Option.value (bool_field json "paused") ~default:false);
          uploading = transfers_of json "uploading";
          downloading = transfers_of json "downloading";
          pending_bytes = int64_field json "pendingBytes";
          bytes_uploaded = int64_field json "bytesUploaded";
          upload_rate = float_field json "uploadBytesPerSec";
        }

let list_field json name =
  match member name json with Some (`List items) -> items | _ -> []

(* Reads a field out of a sub-object that may not be there at all, which is
   every one of these: the daemon leaves out what its frontend does not keep. *)
let sub json name field key =
  Option.bind (member name json) (fun o -> field o key)

let backend_of json =
  {
    backend_name = Option.value (string_field json "name") ~default:"backend";
    role = Option.value (string_field json "role") ~default:"?";
    backend_reachable =
      Option.value (bool_field json "reachable") ~default:false;
    latency_ms = float_field json "latencyMs";
    backend_error = string_field json "error";
    journal_entries = sub json "journal" int_field "entries";
    journal_behind = sub json "journal" int_field "behind";
    corrupted_chunks = sub json "corrupted" int_field "chunks";
    corruption =
      (match
         ( sub json "corrupted" string_field "error",
           sub json "corrupted" bool_field "checked" )
       with
        | Some _, _ -> `Failed
        | None, Some true -> `Checked
        | None, (Some false | None) -> `Unchecked);
  }

(* The frontends of one domain, which on Linux is one. Their queue and byte
   counters are summed rather than picked from the first: two frontends serving
   a domain are each doing part of its work. *)
let frontend_sum json key field =
  match
    List.filter_map (fun f -> field f key) (list_field json "frontends")
  with
    | [] -> None
    | values -> Some (List.fold_left ( + ) 0 values)

let frontend_sum64 json key =
  match
    List.filter_map (fun f -> int64_field f key) (list_field json "frontends")
  with
    | [] -> None
    | values -> Some (List.fold_left Int64.add 0L values)

let frontend_first json key =
  List.find_map (fun f -> string_field f key) (list_field json "frontends")

let domain_stats_of json =
  {
    domain_name = Option.value (string_field json "name") ~default:"domain";
    mount_point = frontend_first json "mountPoint";
    read_only = Option.value (bool_field json "domainReadOnly") ~default:false;
    versioning = Option.value (bool_field json "versioning") ~default:false;
    cache_chunks = sub json "cache" int_field "chunks";
    cache_bytes = sub json "cache" int64_field "bytes";
    cache_max = sub json "cache" int64_field "maxCache";
    in_uploads = frontend_sum json "pendingUploads" int_field;
    in_downloads = frontend_sum json "pendingDownloads" int_field;
    staged = frontend_sum json "stagedFiles" int_field;
    bytes_read = frontend_sum64 json "bytesRead";
    bytes_written = frontend_sum64 json "bytesWritten";
    wal_pending = sub json "wal" int_field "pending";
    wal_stuck = sub json "wal" int_field "stuck";
    backends = List.map backend_of (list_field json "backends");
  }

let of_stats_json json =
  match bool_field json "ok" with
    | Some false | None -> None
    | Some true ->
        let server = member "server" json in
        let process = member "process" json in
        let traffic = member "traffic" json in
        let field o name f = Option.bind o (fun o -> f o name) in
        Some
          {
            host =
              Option.value (field server "hostname" string_field) ~default:"?";
            frontend =
              Option.value (field server "frontend" string_field) ~default:"?";
            pid = Option.value (field server "pid" int_field) ~default:0;
            uptime =
              Option.value
                (field server "uptimeSeconds" float_field)
                ~default:0.;
            cpu_percent =
              Option.value
                (field process "cpuPercentAvg" float_field)
                ~default:0.;
            rss =
              Option.value (field process "rssBytes" int64_field) ~default:0L;
            heap =
              Option.value (field process "heapBytes" int64_field) ~default:0L;
            uploaded =
              Option.value
                (field traffic "bytesUploaded" int64_field)
                ~default:0L;
            up_rate =
              Option.value
                (field traffic "uploadBytesPerSec" float_field)
                ~default:0.;
            downloaded =
              Option.value
                (field traffic "bytesDownloaded" int64_field)
                ~default:0L;
            down_rate =
              Option.value
                (field traffic "downloadBytesPerSec" float_field)
                ~default:0.;
            domain_stats = List.map domain_stats_of (list_field json "domains");
          }
