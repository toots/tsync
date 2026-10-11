type place = { parent : Folder_id.t; name : string }

let compare_place a b =
  match Folder_id.compare a.parent b.parent with
    | 0 -> String.compare a.name b.name
    | c -> c

module Places = Map.Make (struct
  type t = place

  let compare = compare_place
end)

module Ids = Map.Make (Folder_id)

type key = [ `File of place | `Folder of Folder_id.t ]

let compare_key (a : key) (b : key) =
  match (a, b) with
    | `File a, `File b -> compare_place a b
    | `Folder a, `Folder b -> Folder_id.compare a b
    | `File _, `Folder _ -> -1
    | `Folder _, `File _ -> 1

module Keys = Set.Make (struct
  type t = key

  let compare = compare_key
end)

type 'f command =
  [ `File of place * 'f option * 'f option
  | `Folder of Folder_id.t * place option * place option ]

let key_of : 'f command -> key = function
  | `File (p, _, _) -> `File p
  | `Folder (i, _, _) -> `Folder i

let is_null ~equal : 'f command -> bool = function
  | `File (_, a, b) -> Option.equal equal a b
  | `Folder (_, a, b) -> a = b

type 'f base = {
  file : place -> 'f option;
  folder : Folder_id.t -> place option;
  folder_at : place -> Folder_id.t option;
  children : Folder_id.t -> key list;
}

type 'f t = {
  base : 'f base;
  files : 'f option Places.t;
  folders : place option Ids.t;
  at : Folder_id.t list Places.t;
}

let of_base base =
  { base; files = Places.empty; folders = Ids.empty; at = Places.empty }

let empty =
  of_base
    {
      file = (fun _ -> None);
      folder = (fun _ -> None);
      folder_at = (fun _ -> None);
      children = (fun _ -> []);
    }

let file t p =
  match Places.find_opt p t.files with Some v -> v | None -> t.base.file p

let folder t i =
  match Ids.find_opt i t.folders with Some v -> v | None -> t.base.folder i

let present t i = Folder_id.is_root i || folder t i <> None

let folders_at t p =
  let changed = Option.value ~default:[] (Places.find_opt p t.at) in
  match t.base.folder_at p with
    | Some i when not (Ids.mem i t.folders) -> i :: changed
    | _ -> changed

let occupants t p : key list =
  let folders = List.map (fun i -> `Folder i) (folders_at t p) in
  if file t p <> None then `File p :: folders else folders

let set_file t p v = { t with files = Places.add p v t.files }

let set_folder t i v =
  let without =
    match Ids.find_opt i t.folders with
      | Some (Some old) ->
          Places.update old
            (fun ids ->
              match List.filter (( <> ) i) (Option.value ~default:[] ids) with
                | [] -> None
                | ids -> Some ids)
            t.at
      | _ -> t.at
  in
  let at =
    match v with
      | None -> without
      | Some p ->
          Places.update p
            (fun ids -> Some (i :: Option.value ~default:[] ids))
            without
  in
  { t with folders = Ids.add i v t.folders; at }

let set t : 'f command -> 'f t = function
  | `File (p, _, v) -> set_file t p v
  | `Folder (i, _, v) -> set_folder t i v

let apply t commands = List.fold_left set t commands

(* ponytail: scans every changed key; index the changes by parent if a merge
   that removes many folders over a large arrival by state gets slow. *)
let children t d : key list =
  let held : key -> bool = function
    | `File p -> p.parent = d && file t p <> None
    | `Folder i -> (
        match folder t i with Some p -> p.parent = d | None -> false)
  in
  let changed =
    Places.fold (fun p _ acc -> Keys.add (`File p) acc) t.files Keys.empty
    |> Ids.fold (fun i _ acc -> Keys.add (`Folder i) acc) t.folders
  in
  let from_base =
    List.filter (fun k -> not (Keys.mem k changed)) (t.base.children d)
  in
  List.filter held (from_base @ Keys.elements changed)

let to_base t =
  {
    file = file t;
    folder = folder t;
    folder_at = (fun p -> List.nth_opt (folders_at t p) 0);
    children = children t;
  }

let place_of t : key -> place option = function
  | `File p -> if file t p <> None then Some p else None
  | `Folder i -> folder t i

(* The members of the cycle reached by following parents from [i]. *)
let cycle_through t i =
  let rec members j = function
    | [] -> []
    | x :: rest -> if x = j then [x] else x :: members j rest
  in
  let rec up seen j =
    if Folder_id.is_root j then None
    else if List.mem j seen then Some (members j seen)
    else (
      match folder t j with None -> None | Some p -> up (j :: seen) p.parent)
  in
  up [] i

type violation =
  | Missing of Folder_id.t
  | Clash of place * key list
  | Cycle of Folder_id.t list

let rule_of = function Missing _ -> `R1 | Clash _ -> `R2 | Cycle _ -> `R3

let violations_at t (k : key) =
  let missing =
    match (k, place_of t k) with
      | _, Some p when not (present t p.parent) -> [Missing p.parent]
      | `Folder i, None when children t i <> [] -> [Missing i]
      | _ -> []
  in
  let clash =
    match place_of t k with
      | Some p -> (
          match occupants t p with
            | _ :: _ :: _ as keys -> [Clash (p, keys)]
            | _ -> [])
      | None -> []
  in
  let cycle =
    match k with
      | `Folder i -> (
          match cycle_through t i with Some ids -> [Cycle ids] | None -> [])
      | `File _ -> []
  in
  missing @ clash @ cycle

let violation ?(priority = [`R1; `R2; `R3]) t keys =
  let found = List.concat_map (violations_at t) keys in
  List.find_map
    (fun rule -> List.find_opt (fun v -> rule_of v = rule) found)
    priority

let well_formed t keys =
  match violation t keys with
    | None -> Ok ()
    | Some (Missing d) ->
        Error (Printf.sprintf "W1: folder %s is absent" (Folder_id.to_string d))
    | Some (Clash (p, _)) ->
        Error
          (Printf.sprintf "W2: %s/%s is occupied twice"
             (Folder_id.to_string p.parent)
             p.name)
    | Some (Cycle ids) ->
        Error
          (Printf.sprintf "W3: cycle through %s"
             (String.concat ", " (List.map Folder_id.to_string ids)))

let is_batch r commands =
  well_formed (apply r commands) (List.map key_of commands) = Ok ()

type 'f step =
  [ `Set of 'f command | `Park of Folder_id.t * place option * place ]

let run t steps =
  List.fold_left
    (fun t -> function
      | `Set c -> set t c | `Park (i, _, p) -> set_folder t i (Some p))
    t steps

let is_above t ~ancestor i =
  let rec up j =
    j = ancestor
    || (not (Folder_id.is_root j))
       && match folder t j with Some p -> up p.parent | None -> false
  in
  up i

let applicable t : 'f command -> bool = function
  | `File (_, _, None) -> true
  | `File (p, _, Some _) -> present t p.parent && folders_at t p = []
  | `Folder (i, _, None) -> children t i = []
  | `Folder (i, _, Some p) ->
      present t p.parent
      && file t p = None
      && List.for_all (( = ) i) (folders_at t p)
      && not (is_above t ~ancestor:i p.parent)

let rec take ?(limit = max_int) ~temp from commands =
  let pending_folder pending i =
    List.exists (fun c -> key_of c = `Folder i) pending
  in
  let to_park t parked pending =
    let free i = (not (List.mem i parked)) && pending_folder pending i in
    let blocker =
      List.find_map
        (function
          | `File (p, _, Some _) | `Folder (_, _, Some p) ->
              List.find_opt free (folders_at t p)
          | _ -> None)
        pending
    in
    match blocker with
      | Some i -> Some i
      | None ->
          List.find_map
            (function
              | `Folder (i, _, _) when free i && folder t i <> None -> Some i
              | _ -> None)
            pending
  in
  let closes parked c =
    match key_of c with `Folder i -> List.mem i parked | `File _ -> false
  in
  (* [parked]: the folders at a temporary place whose command is not set yet. *)
  let rec go t parked all_parked steps count pending =
    let t, parked, steps, count, blocked =
      List.fold_left
        (fun (t, parked, steps, count, blocked) c ->
          if applicable t c && (count < limit || closes parked c) then
            ( set t c,
              List.filter (fun i -> key_of c <> `Folder i) parked,
              `Set c :: steps,
              count + 1,
              blocked )
          else (t, parked, steps, count, c :: blocked))
        (t, parked, steps, count, [])
        pending
    in
    let blocked = List.rev blocked in
    let park () =
      if count < limit then to_park t all_parked blocked else None
    in
    if blocked = [] then `Done (List.rev steps, [])
    else if List.length blocked < List.length pending then
      go t parked all_parked steps count blocked
    else (
      match park () with
        | Some i ->
            let p = { parent = Folder_id.root; name = temp i } in
            go (set_folder t i (Some p)) (i :: parked) (i :: all_parked)
              (`Park (i, folder t i, p) :: steps)
              count blocked
        | None when parked = [] -> `Done (List.rev steps, blocked)
        | None -> `Stranded parked)
  in
  match go from [] [] [] 0 commands with
    | `Done result -> result
    | `Stranded parked ->
        let stranded c = closes parked c in
        let steps, left =
          take ~limit ~temp from
            (List.filter (fun c -> not (stranded c)) commands)
        in
        (steps, left @ List.filter stranded commands)

let order ~temp from commands =
  match take ~temp from commands with
    | steps, [] -> steps
    | _ -> failwith "Algebra.order: not a batch"

type 'f merged = {
  n : 'f t;
  local : 'f command list;
  pending : 'f command list;
  asides : (place * place) list;
  restored : Folder_id.t list;
}

type rule = [ `R1 | `R2 | `R3 ]

let merge ?priority ~equal ~aside ~l ~before ~theirs () =
  let l = of_base l in
  let r =
    apply l
      (List.map
         (function
           | `File (p, x, _) -> `File (p, None, x)
           | `Folder (i, x, _) -> `Folder (i, None, x))
         before)
  in
  let m = apply r theirs in
  let same a b = Option.equal equal a b in
  let keys = Keys.of_list (List.map key_of before @ List.map key_of theirs) in
  let fresh n ~is_dir (p : place) =
    let taken name =
      occupants n { p with name } <> [] || occupants l { p with name } <> []
    in
    { p with name = aside ~taken ~is_dir p.name }
  in
  let step1 (n, copies) : key -> _ = function
    | `File p ->
        let rv = file r p and lv = file l p and mv = file m p in
        if same lv rv || same lv mv then (set_file n p mv, copies)
        else if same mv rv || mv = None then (n, copies)
        else (set_file n p mv, if lv = None then copies else (p, lv) :: copies)
    | `Folder i ->
        let rv = folder r i and lv = folder l i and mv = folder m i in
        if lv = rv || rv <> mv then (set_folder n i mv, copies) else (n, copies)
  in
  let n, copies = Keys.fold (fun k acc -> step1 acc k) keys (l, []) in
  let n, keys, asides =
    List.fold_left
      (fun (n, keys, asides) (p, v) ->
        let p' = fresh n ~is_dir:false p in
        (set_file n p' v, Keys.add (`File p') keys, (p, p') :: asides))
      (n, keys, []) (List.rev copies)
  in
  let from_m n : key -> bool = function
    | `File p -> same (file n p) (file m p)
    | `Folder i -> folder n i = folder m i
  in
  let restore n d =
    match (folder m d, folder r d) with
      | Some p, _ -> p
      | None, Some p when occupants n p = [] && present n p.parent -> p
      | None, rv ->
          let rec up i =
            match folder r i with
              | Some p when present n p.parent -> p.parent
              | Some p -> up p.parent
              | None -> Folder_id.root
          in
          let name =
            match rv with Some p -> p.name | None -> Folder_id.to_string d
          in
          fresh n ~is_dir:true { parent = up d; name }
  in
  let repair (n, keys, asides, restored) = function
    | Missing d ->
        ( set_folder n d (Some (restore n d)),
          Keys.add (`Folder d) keys,
          asides,
          d :: restored )
    | Clash (p, occupants) ->
        if not (List.exists (from_m n) occupants) then
          failwith "Algebra.merge: a place taken twice by local values";
        List.fold_left
          (fun (n, keys, asides, restored) (k : key) ->
            if from_m n k then (n, keys, asides, restored)
            else (
              match k with
                | `File _ ->
                    let p' = fresh n ~is_dir:false p in
                    ( set_file (set_file n p None) p' (file n p),
                      Keys.add (`File p') keys,
                      (p, p') :: asides,
                      restored )
                | `Folder i ->
                    ( set_folder n i (Some (fresh n ~is_dir:true p)),
                      keys,
                      asides,
                      restored )))
          (n, keys, asides, restored)
          occupants
    | Cycle ids -> (
        let local i = folder m i <> None && folder n i <> folder m i in
        match List.sort Folder_id.compare (List.filter local ids) with
          | i :: _ -> (set_folder n i (folder m i), keys, asides, restored)
          | [] -> failwith "Algebra.merge: a cycle with no local move")
  in
  let rec fix budget ((n, keys, _, _) as acc) =
    match violation ?priority n (Keys.elements keys) with
      | None -> acc
      | Some _ when budget = 0 -> failwith "Algebra.merge: repair does not end"
      | Some v -> fix (budget - 1) (repair acc v)
  in
  let n, keys, asides, restored =
    fix ((10 * Keys.cardinal keys) + 10) (n, keys, asides, [])
  in
  let command ~(from : 'f t) : key -> 'f command = function
    | `File p -> `File (p, file from p, file n p)
    | `Folder i -> `Folder (i, folder from i, folder n i)
  in
  let keys = Keys.elements keys in
  {
    n;
    local =
      List.filter
        (fun c -> not (is_null ~equal c))
        (List.map (command ~from:l) keys);
    pending = List.map (command ~from:m) keys;
    asides = List.rev asides;
    restored = List.rev restored;
  }
