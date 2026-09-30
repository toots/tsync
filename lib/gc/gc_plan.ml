open Tsync_core

type start =
  | Resume_keep of string
  | Begin_keep
  | Resume_close of { after : string; generation : int option }
  | Open of { started : float option; after : string }

let start ~(r0 : Gc_record.read) ~keep =
  match r0 with
    | Unreadable -> Resume_keep ""
    | Record { phase = Abandoning; cursor; _ } -> Resume_keep cursor
    | _ when keep -> Begin_keep
    | Record { phase = Closing; cursor; generation; _ } ->
        Resume_close { after = cursor; generation }
    | Record { phase = Opening | Marking; started; cursor; _ } ->
        Open { started = Some started; after = cursor }
    | Absent -> Open { started = None; after = "" }

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

type anchor = Live | In_trash | No_anchor

type trash =
  | Delete_stale of Key.t list
  | Skip_recent
  | Purge of Key.t list
  | Refuse_live

let trash ~anchor ~cutoff ?(on_demand = false) (entries : (Key.t * float) list)
    =
  let keys = List.map fst entries in
  match anchor with
    | Live when on_demand -> Refuse_live
    | Live ->
        Delete_stale
          (List.filter_map
             (fun (k, mtime) -> if mtime < cutoff then Some k else None)
             entries)
    | (In_trash | No_anchor) when on_demand -> Purge keys
    | In_trash | No_anchor ->
        if List.exists (fun (_, mtime) -> mtime >= cutoff) entries then
          Skip_recent
        else Purge keys

let purge_order (namespaces : (Key.prefix * int) list) =
  List.stable_sort (fun (_, a) (_, b) -> compare b a) namespaces |> List.map fst

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

let journal ~now ~horizon ~cutoff ~cursor entries =
  let keep_from = Int64.of_float (Float.min cutoff (now -. horizon) *. 1000.) in
  List.filter_map
    (fun (e, key) ->
      let named =
        Option.fold ~none:false ~some:(Tsync_sync.Entry_key.equal e) cursor
      in
      if Tsync_sync.Entry_key.ms e < keep_from && not named then Some key
      else None)
    entries

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
