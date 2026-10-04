open Tsync_menu

type row = { id : int; entry : Menu_model.entry; children : row list }

type t = {
  mutable rows : row list;
  mutable revision : int;
  mutable next_id : int;
  mutable opened : float option;
  mutable last_notice : float;
  mutable held : Menu_model.entry list option;
}

let menu_open_bound = 60.
let open_debounce = 1.

let create () =
  {
    rows = [];
    revision = 1;
    next_id = 1;
    opened = None;
    last_notice = neg_infinity;
    held = None;
  }

let revision t = t.revision
let rows t = t.rows
let rec flatten rows = List.concat_map (fun r -> r :: flatten r.children) rows
let all t = flatten t.rows
let find t id = List.find_opt (fun r -> r.id = id) (all t)

let fresh t =
  let id = t.next_id in
  t.next_id <- id + 1;
  id

let submenu_action = function
  | Menu_model.Item { submenu = true; action; _ } -> Some action
  | _ -> None

(* §4.3, row identity. *)
let place t old entries =
  List.mapi
    (fun position entry ->
      match List.nth_opt old position with
        | Some row when row.entry = entry -> row
        | _ ->
            let children =
              match submenu_action entry with
                | None -> []
                | Some action -> (
                    match
                      List.find_opt
                        (fun r -> submenu_action r.entry = Some action)
                        old
                    with
                      | Some previous -> previous.children
                      | None ->
                          List.map
                            (fun entry ->
                              { id = fresh t; entry; children = [] })
                            Menu_model.stats_placeholder)
            in
            { id = fresh t; entry; children })
    entries

let updated t parent =
  t.revision <- t.revision + 1;
  [parent]

let installed t = List.map (fun r -> r.entry) t.rows

let install t entries =
  if entries = installed t then []
  else (
    t.rows <- place t t.rows entries;
    updated t 0)

let install_held t =
  match t.held with
    | None -> []
    | Some entries ->
        t.held <- None;
        install t entries

let open_since t ~now =
  match t.opened with
    | Some since when now -. since < menu_open_bound -> Some since
    | _ -> None

let set_menu t ~now entries =
  if entries = installed t then (
    t.held <- None;
    [])
  else if open_since t ~now <> None then (
    t.held <- Some entries;
    [])
  else (
    t.held <- None;
    install t entries)

let set_stats t entries =
  match
    List.find_opt
      (fun r -> submenu_action r.entry = Some Menu_model.Show_stats)
      t.rows
  with
    | None -> []
    | Some stats when List.map (fun r -> r.entry) stats.children = entries -> []
    | Some stats ->
        let children = place t stats.children entries in
        t.rows <-
          List.map
            (fun r -> if r.id = stats.id then { r with children } else r)
            t.rows;
        updated t stats.id

let opening t ~now id =
  let previous = t.last_notice in
  t.last_notice <- now;
  if id = 0 && now -. previous > open_debounce then (
    let changed = install_held t in
    t.opened <- Some now;
    changed)
  else []

let closed t id =
  if id = 0 then (
    t.opened <- None;
    install_held t)
  else []
