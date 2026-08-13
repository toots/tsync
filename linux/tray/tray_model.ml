type upload = { name : string; rel : string }

type status = {
  name : string;
  uploads : int option;
  downloads : int option;
  paused : bool option;
  uploading : upload list;
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
    pending_bytes = None;
    bytes_uploaded = None;
    upload_rate = None;
    mount = None;
  }

type action =
  | Nothing
  | Open_folder of string
  | Reveal_file of string
  | Set_paused of bool
  | Quit

type item = {
  label : string;
  enabled : bool;
  icon : string option;
  checked : bool option;
  indent : int;
  action : action;
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

(* Decimal, and with the Finder's precision: no fraction under a megabyte, one
   at megabytes, two above, and never a trailing zero. Deliberately not
   [Metrics.human_bytes], which counts in 1024s because [Conf_parsing.parse_size]
   has to read back what it prints -- a size someone typed into config.json
   would move if these two were the same function.

   One deliberate difference from macOS: ByteCountFormatter renders zero as
   "Zero KB", which reads as a fault rather than as nothing to report. *)
let human_bytes n =
  let trim s =
    if String.contains s '.' then (
      let last = ref (String.length s - 1) in
      while !last >= 0 && s.[!last] = '0' do
        decr last
      done;
      if !last >= 0 && s.[!last] = '.' then decr last;
      String.sub s 0 (!last + 1))
    else s
  in
  let scaled unit digits divisor =
    Printf.sprintf "%s %s"
      (trim (Printf.sprintf "%.*f" digits (Int64.to_float n /. divisor)))
      unit
  in
  (* The unit is chosen by what the number rounds to, not by what it is: at zero
     fraction digits 999_999 bytes would otherwise read "1000 KB" instead of
     "1 MB". *)
  let fits digits divisor =
    Int64.to_float n /. divisor < 1000. -. (0.5 /. (10. ** float_of_int digits))
  in
  if n < 0L then "0 bytes"
  else if n = 1L then "1 byte"
  else if n < 1_000L then Printf.sprintf "%Ld bytes" n
  else if fits 0 1e3 then scaled "KB" 0 1e3
  else if fits 1 1e6 then scaled "MB" 1 1e6
  else if fits 2 1e9 then scaled "GB" 2 1e9
  else scaled "TB" 2 1e12

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
    let downloads = sum_opt (fun s -> s.downloads) statuses in
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
  match (s.uploads, s.downloads) with
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

(* Informational rows stay enabled. Disabling them would be the honest thing if
   "enabled" meant "does something", but every menu draws a disabled row grey,
   which is how information ends up looking like a broken command. *)
let info ?icon ?(indent = 0) ?(action = Nothing) label =
  Item { label; enabled = true; icon; checked = None; indent; action }

let render statuses =
  let header = info (Printf.sprintf "tsync — %s" (summary statuses)) in
  let domain s =
    let row =
      info
        (Printf.sprintf "%s — %s" s.name (detail s))
        ~action:(match s.mount with Some m -> Open_folder m | None -> Nothing)
    in
    let shown =
      List.sort (fun (a : upload) b -> compare a.name b.name) s.uploading
    in
    let files =
      List.filteri (fun i _ -> i < max_uploading_shown) shown
      |> List.map (fun (u : upload) ->
          info u.name ~icon:(file_icon u.name) ~indent:1
            ~action:
              (match s.mount with
                | Some m -> Reveal_file (Filename.concat m u.rel)
                | None -> Nothing))
    in
    let hidden = List.length s.uploading - max_uploading_shown in
    let more =
      if hidden > 0 then
        [info (Printf.sprintf "… and %d more" hidden) ~indent:1]
      else []
    in
    (row :: files) @ more
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
      }
  in
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
      }
  in
  {
    icon = icon_name statuses;
    tooltip = Printf.sprintf "tsync — %s" (summary statuses);
    entries =
      ((header :: domains) @ traffic) @ [Separator; pause; Separator; quit];
  }
