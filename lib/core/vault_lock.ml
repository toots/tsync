type t = {
  idle_minutes : int option;
  on_screen_lock : bool;
  max_hours : int option;
}

let none = { idle_minutes = None; on_screen_lock = false; max_hours = None }
let is_none t = t = none

let smaller a b =
  match (a, b) with
    | Some x, Some y -> Some (min x y)
    | Some x, None | None, Some x -> Some x
    | None, None -> None

let strictest a b =
  {
    idle_minutes = smaller a.idle_minutes b.idle_minutes;
    on_screen_lock = a.on_screen_lock || b.on_screen_lock;
    max_hours = smaller a.max_hours b.max_hours;
  }

let to_json t : Yojson.Safe.t =
  let limit name = Option.map (fun v -> (name, `Int v)) in
  `Assoc
    (List.filter_map Fun.id
       [
         limit "idleMinutes" t.idle_minutes;
         (if t.on_screen_lock then Some ("onScreenLock", `Bool true) else None);
         limit "maxHours" t.max_hours;
       ])

let of_json : Yojson.Safe.t -> (t, string) result = function
  | `Assoc l -> (
      let limit name ~max =
        match List.assoc_opt name l with
          | None -> Ok None
          | Some (`Int v) when v >= 1 && v <= max -> Ok (Some v)
          | Some _ -> Error (Printf.sprintf "%s: expected 1 to %d" name max)
      in
      let on_screen_lock =
        match List.assoc_opt "onScreenLock" l with
          | None -> Ok false
          | Some (`Bool b) -> Ok b
          | Some _ -> Error "onScreenLock: expected a bool"
      in
      match
        ( limit "idleMinutes" ~max:1440,
          on_screen_lock,
          limit "maxHours" ~max:720 )
      with
        | Ok idle_minutes, Ok on_screen_lock, Ok max_hours ->
            Ok { idle_minutes; on_screen_lock; max_hours }
        | Error e, _, _ | _, Error e, _ | _, _, Error e -> Error e)
  | _ -> Error "expected an object"
