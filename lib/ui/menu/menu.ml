type transfer = { name : string; rel : string }

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
  mount : string option;
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
    mount = None;
  }

(* What the submenu draws, which is `tsync stats' with most of it left out: the
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

type action =
  | Nothing
  | Open_folder of string
  | Reveal_file of string
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

let is_transferring s =
  Option.value s.uploads ~default:0 + Option.value s.downloads ~default:0 > 0

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

(* The same formatter `tsync stats' prints with, so one byte count does not read
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

(* [downloads] counts chunk fetches in flight, which is not what the rows under
   this count: one file is many chunks, and several files can share one fetch.
   Where there are rows, they are what the number has to agree with. *)
let download_count s =
  match s.downloading with
    | [] -> s.downloads
    | files -> Some (List.length files)

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
  match bytes_uploaded statuses with
    | None -> None
    | Some sent ->
        let head = Printf.sprintf "%s sent" (human_bytes sent) in
        let pending = pending_bytes statuses in
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

   ponytail: placeholders borrowed from the icon theme, pending four of our own.
   They are only borrowed, so they are chosen for being present rather than for
   reading as one set -- and being present is not portable: the spec's
   [network-transmit-receive] is in neither Breeze nor a current Adwaita, so a
   name has to be checked against a real theme before it goes here. Shipping our
   own into hicolor, which every theme inherits, ends the guessing. *)
let icon_name statuses =
  if all_unreachable statuses then "dialog-warning"
  else if all_paused statuses then "media-playback-pause"
  else if List.exists is_transferring statuses then "state-sync"
  else "view-refresh"

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
   what, which is all a menu row can carry. The rest is what `tsync stats' is
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
  info ~indent:1
    (String.concat " · "
       (Printf.sprintf "%s (%s) — %s" b.backend_name b.role health :: journal))

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
let file_rows s transfers =
  let shown =
    List.sort (fun (a : transfer) b -> compare a.name b.name) transfers
  in
  let rows =
    List.filteri (fun i _ -> i < max_uploading_shown) shown
    |> List.map (fun (u : transfer) ->
        info u.name ~icon:(file_icon u.name) ~indent:1
          ~action:
            (match s.mount with
              | Some m -> Reveal_file (Filename.concat m u.rel)
              | None -> Nothing))
  in
  let hidden = List.length transfers - max_uploading_shown in
  rows
  @
  if hidden > 0 then [info (Printf.sprintf "… and %d more" hidden) ~indent:1]
  else []

let render statuses =
  let header = info (Printf.sprintf "tsync — %s" (summary statuses)) in
  let domain s =
    let row =
      info
        (Printf.sprintf "%s — %s" s.name (detail s))
        ~action:(match s.mount with Some m -> Open_folder m | None -> Nothing)
    in
    (row :: file_rows s s.uploading) @ file_rows s s.downloading
  in
  let domains =
    if statuses = [] then [] else Separator :: List.concat_map domain statuses
  in
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
  (* "Quit tsync" on macOS, where quitting the app is quitting the whole thing.
     Here the daemon is a service this process does not own, and someone hiding
     an icon must not find their files stopped syncing. *)
  let quit =
    Item
      {
        label = "Quit tsync tray";
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
      ((header :: domains) @ traffic)
      @ [Separator; stats; pause; Separator; quit];
  }
