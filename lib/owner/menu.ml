type answer = (Protocol.status, string) result

let all f = function [] -> false | l -> List.for_all f l
let paused = function Ok (s : Protocol.status) -> s.paused | Error _ -> false
let unreachable = function Ok _ -> false | Error _ -> true

let statuses answers =
  List.filter_map
    (fun (_, a) ->
      match a with Ok (s : Protocol.status) -> Some s | Error _ -> None)
    answers

let sum f answers = List.fold_left (fun n s -> n + f s) 0 (statuses answers)
let uploads = sum (fun s -> s.pending_uploads)
let downloads = sum (fun s -> s.pending_downloads)

let summary answers =
  let up = uploads answers and down = downloads answers in
  let all_statuses = List.map snd answers in
  if answers = [] then "No domains configured"
  else if all unreachable all_statuses then "Daemon not running"
  else if up + down = 0 then
    if all paused all_statuses then "Paused" else "Idle"
  else
    Printf.sprintf "Uploading %d · Downloading %d%s" up down
      (if List.exists paused all_statuses then " · paused" else "")

let icon answers =
  let all_statuses = List.map snd answers in
  if answers = [] || all unreachable all_statuses then "tsync-error-symbolic"
  else if all paused all_statuses then "tsync-paused-symbolic"
  else if uploads answers + downloads answers > 0 then "tsync-sync-symbolic"
  else "tsync-idle-symbolic"

let entry ?(enabled = true) ?(indent = 0) ?checked ?(submenu = false) label
    action =
  `Assoc
    ([
       ("label", `String label);
       ("enabled", `Bool enabled);
       ("indent", `Int indent);
     ]
    @ (match checked with Some c -> [("checked", `Bool c)] | None -> [])
    @ (if submenu then [("submenu", `Bool true)] else [])
    @ match action with `Null -> [] | a -> [("action", a)])

(* 07 §5.8: no time is shown under a minute. *)
let time_left seconds =
  if seconds < 60. then None else Some (Tsync_core.Narrate.duration seconds)

let transfer_rows answers =
  let all_uploading =
    List.concat_map
      (fun (s : Protocol.status) -> s.uploading)
      (statuses answers)
  in
  let shown = List.filteri (fun i _ -> i < 5) all_uploading in
  let more = uploads answers - List.length shown in
  let uploads_rows =
    List.map
      (fun (t : Protocol.transfer) ->
        entry ~enabled:false ~indent:1 t.name `Null)
      shown
    @
    if more > 0 && shown <> [] then
      [
        entry ~enabled:false ~indent:1
          (Printf.sprintf "… and %d more" more)
          `Null;
      ]
    else []
  in
  let download_rows =
    List.concat_map
      (fun (s : Protocol.status) ->
        List.map
          (fun (t : Protocol.transfer) ->
            let percent = if t.size > 0 then 100 * t.bytes / t.size else 0 in
            entry ~indent:1
              (Printf.sprintf "%s — %d%%" t.name percent)
              (`Assoc
                 [
                   ( "reveal",
                     `Assoc
                       [("domain", `String s.domain); ("rel", `String t.rel)] );
                 ]))
          s.downloading)
      (statuses answers)
  in
  let sent = sum (fun s -> s.traffic.up_bytes) answers
  and to_go = sum (fun s -> s.pending_bytes) answers
  and rate =
    List.fold_left
      (fun r (s : Protocol.status) -> r +. s.traffic.up_rate)
      0. (statuses answers)
  in
  let traffic =
    if sent + to_go = 0 then []
    else
      [
        entry ~enabled:false
          (Printf.sprintf "%s sent · %s to go"
             (Tsync_core.Narrate.size sent)
             (Tsync_core.Narrate.size to_go))
          `Null;
      ]
  in
  let rate_row =
    if uploads answers = 0 || rate <= 0. then []
    else
      [
        entry ~enabled:false
          (Tsync_core.Narrate.rate rate
          ^ Option.fold ~none:""
              ~some:(fun t -> " · " ^ t ^ " left")
              (time_left (float_of_int to_go /. rate)))
          `Null;
      ]
  in
  uploads_rows @ download_rows @ traffic @ rate_row

let render answers =
  let all_statuses = List.map snd answers in
  let hold = all paused all_statuses in
  `Assoc
    [
      ("icon", `String (icon answers));
      ("tooltip", `String (summary answers));
      ( "entries",
        `List
          (List.map
             (fun (name, _) ->
               entry name (`Assoc [("openFolder", `String name)]))
             answers
          @ transfer_rows answers
          @ [
              `Assoc [("separator", `Bool true)];
              entry ~submenu:true "Stats" (`Assoc [("stats", `Bool true)]);
              entry ~checked:hold
                ~enabled:(answers <> [] && not (all unreachable all_statuses))
                "Hold changes"
                (`Assoc [("setPaused", `Bool (not hold))]);
            ]) );
    ]

let stats_entries text =
  List.filter_map
    (fun line ->
      if String.trim line = "" then None
      else Some (entry ~enabled:false line `Null))
    (String.split_on_char '\n' text)
