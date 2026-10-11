open Tsync_core

type start =
  | Resume_keep of string
  | Begin_keep
  | Resume_close of { after : string; generation : int option }
  | Open of { started : float option; after : string; marking : bool }

let start ~(r0 : Gc_record.read) ~keep =
  match r0 with
    | Unreadable -> Resume_keep ""
    | Record { phase = Abandoning; cursor; _ } -> Resume_keep cursor
    | _ when keep -> Begin_keep
    | Record { phase = Closing; cursor; generation; _ } ->
        Resume_close { after = cursor; generation }
    | Record { phase = Opening; started; cursor; _ } ->
        Open { started = Some started; after = cursor; marking = false }
    | Record { phase = Marking; started; cursor; _ } ->
        Open { started = Some started; after = cursor; marking = true }
    | Absent -> Open { started = None; after = ""; marking = false }

let namespaces ~manifests ~versions ~after =
  List.sort String.compare
    (List.map (fun id -> "m/" ^ id) manifests
    @ List.map (fun id -> "v/" ^ id) versions)
  |> List.filter (fun n -> String.compare n after > 0)

let namespace_prefix d ns =
  match String.split_on_char '/' ns with
    | ["m"; id] -> Key.prefix (Key.prefix_to_string (Key.manifests d) ^ id ^ "/")
    | ["v"; id] -> Key.prefix (Key.prefix_to_string (Key.versions d) ^ id ^ "/")
    | _ -> Fail.invalid "%S is not a namespace tag" ns

let closing_generation = function
  | Some g when g mod 2 = 1 -> Ok g
  | Some g -> Ok (g + 1)
  | None -> Error "the collection generation is unreadable"

let settled_generation g = g + 1

let doomed ~shard ~names ~in_surviving =
  List.filter_map
    (fun n ->
      match Chunk_key.of_string n with
        | Some c when Chunk_key.shard c = shard && not (in_surviving c) ->
            Some c
        | _ -> None)
    names
  |> List.sort_uniq Chunk_key.compare

type keep = Rename_shard | Push_down | Move_across

let keep_plan ~surviving ~outgoing =
  if surviving = 0 then Rename_shard
  else if surviving + 1 < outgoing - surviving then Push_down
  else Move_across

let after ~cursor names =
  List.filter
    (fun n -> String.compare n cursor > 0)
    (List.sort String.compare names)

let version_time key =
  match Int64.of_string_opt (Key.leaf key) with
    | Some ns when ns >= 0L -> Some ns
    | _ -> None

let versions ~cutoff keys =
  let cutoff_ns = Int64.of_float (cutoff *. 1e9) in
  List.filter
    (fun k ->
      match version_time k with Some ns -> ns < cutoff_ns | None -> false)
    keys

let entry_number key = int_of_string_opt (Key.leaf key)

let log ~now ~retention ~tree_head (entries : (Key.t * float) list) =
  let numbered =
    List.filter_map
      (fun (key, mtime) ->
        Option.map (fun n -> (n, key, mtime)) (entry_number key))
      entries
    |> List.sort compare
  in
  let head = List.fold_left (fun acc (n, _, _) -> max acc n) 0 numbered in
  List.filter_map
    (fun (n, key, mtime) ->
      if n <= tree_head && n <> head && mtime < now -. retention then Some key
      else None)
    numbered

let takeovers ~tree_head keys =
  List.filter
    (fun key ->
      match String.split_on_char '-' (Key.leaf key) with
        | n :: _ -> (
            match int_of_string_opt n with
              | Some n -> n <= tree_head
              | None -> false)
        | [] -> false)
    keys

type share = Expired | Kept | Other_domain | Unparseable

let share ~domain ~now body =
  match Yojson.Safe.from_string body with
    | `Assoc f -> (
        match (List.assoc_opt "domain" f, List.assoc_opt "expires" f) with
          | Some (`String d), Some ((`Int _ | `Float _) as e) ->
              let expires =
                match e with `Int i -> float_of_int i | `Float x -> x
              in
              if d <> Domain_name.to_string domain then Other_domain
              else if expires < now then Expired
              else Kept
          | _ -> Unparseable)
    | _ -> Unparseable
    | exception _ -> Unparseable

type survey = { reclaimable : int; bytes : int; keys : Key.t list }

let unreferenced ~referenced (listing : Tsync_store.Store.entry list) =
  List.fold_left
    (fun acc (e : Tsync_store.Store.entry) ->
      match Key.chunk_of e.key with
        | Some c when not (referenced c) ->
            {
              reclaimable = acc.reclaimable + 1;
              bytes = acc.bytes + e.size;
              keys = e.key :: acc.keys;
            }
        | _ -> acc)
    { reclaimable = 0; bytes = 0; keys = [] }
    listing
  |> fun s -> { s with keys = List.rev s.keys }
