type answer = (Protocol.status, string) result

let all f = function [] -> false | l -> List.for_all f l
let paused = function Ok (s : Protocol.status) -> s.paused | Error _ -> false
let unreachable = function Ok _ -> false | Error _ -> true

let uploads answers =
  List.fold_left
    (fun n (_, a) ->
      match a with
        | Ok (s : Protocol.status) -> n + s.pending_uploads
        | Error _ -> n)
    0 answers

let summary answers =
  let up = uploads answers and statuses = List.map snd answers in
  if answers = [] then "No domains configured"
  else if all unreachable statuses then "Daemon not running"
  else if up = 0 then if all paused statuses then "Paused" else "Idle"
  else
    Printf.sprintf "Uploading %d · Downloading %d%s" up 0
      (if List.exists paused statuses then " · paused" else "")

let icon answers =
  let statuses = List.map snd answers in
  if answers = [] || all unreachable statuses then "tsync-error-symbolic"
  else if all paused statuses then "tsync-paused-symbolic"
  else if uploads answers > 0 then "tsync-sync-symbolic"
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
    @ [("action", action)])

(* ponytail: no upload, download, traffic or rate rows yet: the status reply
   does not carry those figures; add them with its fields (07 §5.5). *)
let render answers =
  let statuses = List.map snd answers in
  let hold = all paused statuses in
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
          @ [
              `Assoc [("separator", `Bool true)];
              entry ~submenu:true "Stats" (`Assoc [("stats", `Bool true)]);
              entry ~checked:hold
                ~enabled:(answers <> [] && not (all unreachable statuses))
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
