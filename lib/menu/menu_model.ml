type action =
  | Nothing
  | Open_folder of string
  | Reveal of { domain : string; rel : string }
  | Set_paused of bool
  | Show_stats
  | Show_codes
  | Copy_code of { domain : string; id : string }
  | Unlock of string
  | Seen_machines of string
  | Copy_report
  | Show_passwords
  | Copy_password of { domain : string; id : string }
  | Quit

type item = {
  label : string;
  enabled : bool;
  icon : string option;
  checked : bool option;
  indent : int;
  action : action;
  submenu : bool;
  vault : string option;
}

type entry = Separator | Item of item
type state = [ `Idle | `Sync | `Paused | `Error ]

let icon_name = function
  | `Idle -> "tsync-idle-symbolic"
  | `Sync -> "tsync-sync-symbolic"
  | `Paused -> "tsync-paused-symbolic"
  | `Error -> "tsync-error-symbolic"

type t = { icon : state; tooltip : string; entries : entry list }

let file_rows = 5
let label_max = 64
let bar_cells = 10

let row ?(enabled = true) ?icon ?checked ?(indent = 0) ?(submenu = false)
    ?(action = Nothing) ?vault label =
  Item { label; enabled; icon; checked; indent; action; submenu; vault }

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

let progress_bar ~moved ~total =
  let share n = max 0 (min n (n * moved / total)) in
  let filled = share bar_cells in
  let cells n glyph = String.concat "" (List.init n (fun _ -> glyph)) in
  Printf.sprintf "%s%s %d%%" (cells filled "▰")
    (cells (bar_cells - filled) "▱")
    (share 100)

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
let string_of_yojson = function `String s -> Ok s | _ -> Error "not a string"

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
  read_only : flag; [@key "readOnly"] [@default false]
  uploading : transfer list; [@of_yojson items transfer_of_yojson] [@default []]
  downloading : transfer list;
      [@of_yojson items transfer_of_yojson] [@default []]
  pending_bytes : count; [@key "pendingBytes"] [@default None]
  failing : string option; [@default None]
  traffic : traffic option;
      [@of_yojson lenient traffic_of_yojson] [@default None]
  new_machines : string list;
      [@key "newMachines"] [@of_yojson items string_of_yojson] [@default []]
  vault_backup_overdue : flag; [@key "vaultBackupOverdue"] [@default false]
  mount : text; [@default None]
  extensions : string list; [@of_yojson items string_of_yojson] [@default []]
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

let waiting ~uploads ~downloads =
  String.concat ", "
    ((if uploads > 0 then [Printf.sprintf "%d to upload" uploads] else [])
    @ if downloads > 0 then [Printf.sprintf "%d to download" downloads] else []
    )

(* §5: a domain's state, and the sentence that says what it means. *)
let state = function
  | None -> ("Not answering", None)
  | Some s when s.paused ->
      ( "Paused",
        Some "Changes stay on this machine and downloads wait until you resume."
      )
  | Some { failing = Some why; _ } ->
      ("Not syncing", Some (why ^ ". Retried until it works."))
  | Some s when s.read_only ->
      ("Read-only", Some "This domain can't be changed from this machine.")
  | Some s when moving s ->
      ( "Syncing",
        Some (waiting ~uploads:(uploads s) ~downloads:(download_count s)) )
  | Some _ -> ("Up to date", None)

let progress_row (t : transfer) =
  let bar =
    match (t.bytes, t.size) with
      | Some moved, Some total when total > 0 -> [progress_bar ~moved ~total]
      | _ -> []
  in
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
  line ~indent:2 (bar @ amount @ speed @ left)

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

let english_list = function
  | [] -> ""
  | [one] -> one
  | l ->
      let rev = List.rev l in
      String.concat ", " (List.rev (List.tl rev)) ^ " and " ^ List.hd rev

(* §5: what the domain holds, and where. *)
let contents_row s =
  let has e = List.mem e s.extensions in
  let extras =
    (if has "passwords" then ["passwords"] else [])
    @ (if has "totp" then ["one-time codes"] else [])
    @
    if has "vault" && not (has "passwords" || has "totp") then
      ["an encrypted vault"]
    else []
  in
  match (extras, s.mount) with
    | [], None -> []
    | _ ->
        [
          row ~indent:1
            (join (english_list ("Files" :: extras) :: part ellipsis s.mount));
        ]

let machine_rows name s =
  match s.new_machines with
    | [] -> []
    | machines ->
        List.map
          (fun m ->
            row ~indent:1 ~icon:"computer" (m ^ " can now unlock this vault"))
          machines
        @ [row ~indent:1 ~action:(Seen_machines name) "Mark as seen"]

let domain_rows (name, status) =
  let label, sentence = state status in
  let sentence = Option.to_list (Option.map (row ~indent:1) sentence) in
  let rows =
    match status with
      | None -> sentence
      | Some s ->
          contents_row s @ sentence @ machine_rows name s
          @ (if s.vault_backup_overdue then
               [
                 row ~indent:1 ~icon:"dialog-warning"
                   "The vault's backup is overdue";
               ]
             else [])
          @ file_rows_of name s.uploading
          @ file_rows_of name s.downloading
  in
  row ~action:(Open_folder name) (name ^ " — " ^ label) :: rows

let render ?quit ?(codes = []) ?(passwords = []) domains =
  let reachable = List.filter_map snd domains in
  let all_unreachable = reachable = [] in
  let all_paused =
    (not all_unreachable) && List.for_all (fun s -> s.paused) reachable
  in
  let total f = List.fold_left (fun n s -> n + f s) 0 reachable in
  (* §4: the row of a paused domain says Paused, so its failure is not the
     summary's. *)
  let any_failing =
    List.exists (fun s -> s.failing <> None && not s.paused) reachable
  in
  let summary =
    if domains = [] then "No domains configured"
    else if all_unreachable then "Daemon not running"
    else if any_failing then "Not syncing"
    else if all_paused then "Paused"
    else (
      match
        waiting ~uploads:(total uploads) ~downloads:(total download_count)
      with
        | "" -> "Up to date"
        | counts -> "Syncing: " ^ counts)
  in
  let tooltip = "tsync — " ^ summary in
  let icon =
    if all_unreachable || any_failing then `Error
    else if all_paused then `Paused
    else if List.exists moving reachable then `Sync
    else `Idle
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
    @ [Separator; row ~submenu:true ~action:Show_stats "Details"]
    @ (if codes = [] then []
       else [row ~submenu:true ~action:Show_codes "One-time codes"])
    @ (if passwords = [] then []
       else [row ~submenu:true ~action:Show_passwords "Passwords"])
    @ [
        row ~checked:all_paused ~enabled:(not all_unreachable)
          ~action:(Set_paused (not all_paused)) "Pause syncing";
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

type corrupted = {
  checked : flag; [@default false]
  chunks : count; [@default None]
}
[@@deriving of_yojson { strict = false }]

type backend = {
  name : text; [@default None]
  role : text; [@default None]
  reach : reach option; [@of_yojson lenient reach_of_yojson] [@default None]
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
  bytes : count; [@default None]
  max_cache : count; [@key "maxCache"] [@default None]
  pinned_bytes : count; [@key "pinnedBytes"] [@default None]
}
[@@deriving of_yojson { strict = false }]

type queues = {
  pending_files : count; [@key "pendingFiles"] [@default None]
  bytes_owed : count; [@key "bytesOwed"] [@default None]
  parked : count; [@default None]
}
[@@deriving of_yojson { strict = false }]

type cannot_follow = { entry : count [@default None] }
[@@deriving of_yojson { strict = false }]

type sync = {
  pending : count; [@default None]
  cannot_follow : cannot_follow option;
      [@key "cannotFollow"]
      [@of_yojson lenient cannot_follow_of_yojson]
      [@default None]
}
[@@deriving of_yojson { strict = false }]

type domain = {
  name : string;
  unanswered : flag; [@default false]
  settings : settings option;
      [@of_yojson lenient settings_of_yojson] [@default None]
  cache : cache option; [@of_yojson lenient cache_of_yojson] [@default None]
  queues : queues option; [@of_yojson lenient queues_of_yojson] [@default None]
  sync : sync option; [@of_yojson lenient sync_of_yojson] [@default None]
  backends : backend list; [@of_yojson items backend_of_yojson] [@default []]
}
[@@deriving of_yojson { strict = false }]

type server = { uptime : number [@key "uptimeSeconds"] [@default None] }
[@@deriving of_yojson { strict = false }]

type usage = { rss_bytes : count [@key "rssBytes"] [@default None] }
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

(* §6: a count and its noun, singular for one. *)
let counted n noun = Printf.sprintf "%d %s%s" n noun (if n = 1 then "" else "s")

let backend_row (b : backend) =
  let role =
    match b.role with
      | Some "readOnly" -> "read-only"
      | Some r -> r
      | None -> "?"
  in
  let connection =
    match b.reach with
      | None -> ""
      | Some { reachable = true; latency_ms = None; _ } -> ": connected"
      | Some { reachable = true; latency_ms = Some ms; _ } ->
          Printf.sprintf ": connected, %.0f ms" (Float.round ms)
      | Some { error = None | Some ""; _ } -> ": unreachable"
      | Some { error = Some e; _ } -> ": unreachable: " ^ ellipsis e
  in
  let damage =
    match b.corrupted with
      | Some { checked = true; chunks = Some n } when n > 0 ->
          [counted n "damaged chunk" ^ " — run tsync data-integrity"]
      | _ -> []
  in
  row ~indent:1
    (join
       (Printf.sprintf "%s (%s)%s"
          (Option.value ~default:"?" b.name)
          role connection
       :: damage))

let domain_details (d : domain) =
  let traits =
    match d.settings with
      | None -> []
      | Some s ->
          (if s.read_only then ["read-only"] else [])
          @ if s.versioning then ["keeps versions"] else []
  in
  let queued f = Option.bind d.queues f and sync f = Option.bind d.sync f in
  let cache =
    match d.cache with
      | Some { bytes = Some bytes; max_cache; pinned_bytes } ->
          [
            row ~indent:1
              (Printf.sprintf "Cache: %s%s%s" (size bytes)
                 (match positive max_cache with
                   | Some max -> " of " ^ size max
                   | None -> "")
                 (match positive pinned_bytes with
                   | Some p -> ", " ^ size p ^ " kept offline"
                   | None -> ""));
          ]
      | _ -> []
  in
  let to_upload =
    part
      (fun n ->
        row ~indent:1
          (Printf.sprintf "To upload: %s%s" (counted n "file")
             (match queued (fun q -> q.bytes_owed) with
               | Some b -> ", " ^ size b
               | None -> "")))
      (positive (queued (fun q -> q.pending_files)))
  in
  row (d.name ^ if traits = [] then "" else " — " ^ String.concat ", " traits)
  :: cache
  @ to_upload
  @ part
      (fun n -> row ~indent:1 (counted n "upload" ^ " waiting to be retried"))
      (positive (queued (fun q -> q.parked)))
  @ part
      (fun n -> row ~indent:1 (counted n "change" ^ " to apply"))
      (positive (sync (fun s -> s.pending)))
  @ part
      (fun n -> row ~indent:1 (Printf.sprintf "Can't follow change %d" n))
      (sync (fun s -> Option.bind s.cannot_follow (fun c -> c.entry)))
  @ List.map backend_row d.backends

let service_row (s : stats) =
  let self f = Option.bind s.self f in
  let running =
    part
      (fun up ->
        match duration up with
          | Some d -> "running " ^ d
          | None -> "just started")
      (Option.bind (self (fun s -> s.server)) (fun s -> s.uptime))
  and memory =
    part
      (fun b -> size b ^ " memory")
      (Option.bind (self (fun s -> s.usage)) (fun u -> u.rss_bytes))
  in
  match running @ memory with
    | [] -> []
    | parts ->
        [
          row
            (match s.domains with
              | [] -> "Service: " ^ join parts
              | domains ->
                  Printf.sprintf "Service for %s: %s"
                    (String.concat ", "
                       (List.map (fun (d : domain) -> d.name) domains))
                    (join parts));
        ]

let traffic_row replies =
  let summed f = sum_known ( + ) 0 (List.map f replies)
  and rates f = sum_known ( +. ) 0. (List.map f replies) in
  let traffic f (s : stats) =
    Option.bind (Option.bind s.self (fun s -> s.traffic)) f
  in
  let flow name bytes speed =
    part
      (fun b ->
        Printf.sprintf "%s %s%s" name (size b)
          (match speed with
            | Some r when r > 0. -> Printf.sprintf " (%s)" (rate r)
            | _ -> ""))
      bytes
  in
  line
    (flow "Sent"
       (summed (traffic (fun t -> t.up_bytes)))
       (rates (traffic (fun t -> t.up_rate)))
    @ flow "received"
        (summed (traffic (fun t -> t.down_bytes)))
        (rates (traffic (fun t -> t.down_rate))))

let stats ?(report = false) replies =
  let separated = function
    | [] -> []
    | first :: rest -> first @ List.concat_map (fun l -> Separator :: l) rest
  in
  match replies with
    | [] -> [row "No daemon answering"]
    | replies ->
        let device =
          List.concat_map service_row replies @ traffic_row replies
        in
        ((match
            List.concat_map
              (fun (s : stats) -> List.map domain_details s.domains)
              replies
            @ if device = [] then [] else [device]
          with
           | [] -> [[row "Nothing reported"]]
           | sections -> sections)
        @ if report then [[row ~action:Copy_report "Copy report"]] else [])
        |> separated

(* §7, §7.1: a vault extension's listing, or why there is none. *)
type 'a answer = Answered of 'a | Locked | No_vault | Not_answering

let answer_of_json read = function
  | None -> Not_answering
  | Some j -> (
      let field k = match j with `Assoc l -> List.assoc_opt k l | _ -> None in
      match (field "ok", field "code") with
        | Some (`Bool true), _ -> Answered (read field)
        | _, Some (`String "locked") -> Locked
        | _, Some (`String "not_found") -> No_vault
        | _ -> Not_answering)

let refused_rows ~indent domain = function
  | Locked -> [row ~indent ~action:(Unlock domain) "Locked — unlock…"]
  | No_vault -> [row ~indent "No vault — run tsync vault init"]
  | Not_answering | Answered _ -> [row ~indent "not answering"]

(* A header row per domain when there are several (vault §8.1 marks it). *)
let per_domain ~none rows = function
  | [] -> [row none]
  | [one] -> rows ~indent:0 one
  | several ->
      List.concat_map
        (fun ((domain, _) as one) ->
          row ~vault:domain domain :: rows ~indent:1 one)
        several

let listed of_yojson field =
  match field "records" with
    | Some j -> Result.get_ok (items of_yojson j)
    | None -> []

type record = {
  id : string;
  issuer : string; [@default ""]
  account : string; [@default ""]
}
[@@deriving of_yojson { strict = false }]

type code_list = { records : record list; unreadable : int }
type codes = code_list answer

let codes_of_json =
  answer_of_json (fun field ->
      {
        records = listed record_of_yojson field;
        unreadable =
          (match field "corrupt" with
            | Some (`List l) -> List.length l
            | _ -> 0);
      })

let codes_placeholder = [row "Reading…"]

let either_label first second =
  match (first, second) with "", s -> s | f, "" -> f | f, s -> f ^ " — " ^ s

let domain_codes ~indent (domain, codes) =
  match codes with
    | Answered { records; unreadable } ->
        (if records = [] then [row ~indent "No codes"] else [])
        @ List.map
            (fun r ->
              row ~indent
                ~action:(Copy_code { domain; id = r.id })
                (ellipsis (either_label r.issuer r.account)))
            records
        @
        if unreadable > 0 then
          [
            row ~indent
              (Printf.sprintf "%d unreadable — run tsync totp list" unreadable);
          ]
        else []
    | refused -> refused_rows ~indent domain refused

let codes = per_domain ~none:"No codes" domain_codes

type login = {
  id : string;
  kind : string; [@default ""]
  title : string; [@default ""]
  username : string; [@default ""]
}
[@@deriving of_yojson { strict = false }]

type passwords = login list answer

let passwords_of_json = answer_of_json (listed login_of_yojson)
let passwords_placeholder = [row "Reading…"]

(* §7.1: notes and passkeys hold no password. *)
let domain_passwords ~indent (domain, passwords) =
  match passwords with
    | Answered logins -> (
        match List.filter (fun (l : login) -> l.kind = "login") logins with
          | [] -> [row ~indent "No passwords"]
          | logins ->
              List.map
                (fun (l : login) ->
                  row ~indent
                    ~action:(Copy_password { domain; id = l.id })
                    (ellipsis (either_label l.title l.username)))
                logins)
    | refused -> refused_rows ~indent domain refused

let passwords = per_domain ~none:"No passwords" domain_passwords

let action_to_yojson = function
  | Nothing -> `Assoc []
  | Open_folder domain -> `Assoc [("openFolder", `String domain)]
  | Reveal { domain; rel } ->
      `Assoc
        [("reveal", `Assoc [("domain", `String domain); ("rel", `String rel)])]
  | Set_paused paused -> `Assoc [("setPaused", `Bool paused)]
  | Show_stats -> `Assoc [("stats", `Bool true)]
  | Show_codes -> `Assoc [("codes", `Bool true)]
  | Copy_code { domain; id } ->
      `Assoc
        [("copyCode", `Assoc [("domain", `String domain); ("id", `String id)])]
  | Unlock domain -> `Assoc [("unlock", `String domain)]
  | Seen_machines domain -> `Assoc [("seenMachines", `String domain)]
  | Copy_report -> `Assoc [("copyReport", `Bool true)]
  | Show_passwords -> `Assoc [("passwords", `Bool true)]
  | Copy_password { domain; id } ->
      `Assoc
        [
          ( "copyPassword",
            `Assoc [("domain", `String domain); ("id", `String id)] );
        ]
  | Quit -> `Assoc [("quit", `Bool true)]

(* §7: a row's icon is not sent. *)
type wire_item = {
  label : string;
  enabled : bool;
  indent : int;
  action : action;
  checked : bool option; [@default None]
  submenu : bool; [@default false]
  vault : string option; [@default None]
}
[@@deriving to_yojson]

type separator = { separator : bool } [@@deriving to_yojson]

let entry_to_json = function
  | Separator -> separator_to_yojson { separator = true }
  | Item { label; enabled; indent; action; checked; submenu; vault; icon = _ }
    ->
      wire_item_to_yojson
        { label; enabled; indent; action; checked; submenu; vault }

type json = Yojson.Safe.t

let json_to_yojson j = j

type wire = { icon : string; tooltip : string; entries : json list }
[@@deriving to_yojson]

let to_json (t : t) =
  wire_to_yojson
    {
      icon = icon_name t.icon;
      tooltip = t.tooltip;
      entries = List.map entry_to_json t.entries;
    }
