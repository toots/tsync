type t = string
type prefix = string

let of_string s = if Names.valid_key s then Some s else None

let v ?(op = "") s =
  if Names.valid_key s then s else Fail.invalid ~op "invalid key %S" s

let prefix_of_string s = if Names.valid_prefix s then Some s else None

let prefix ?(op = "") s =
  if Names.valid_prefix s then s else Fail.invalid ~op "invalid prefix %S" s

let to_string k = k
let prefix_to_string p = p
let as_prefix k = k ^ "/"
let under p k = String.starts_with ~prefix:p k
let equal = String.equal
let compare = String.compare

let rel p k =
  if under p k then
    String.sub k (String.length p) (String.length k - String.length p)
  else invalid_arg "Key.rel"

let root = "tsync/"
let domain_prefix d = "tsync/" ^ Domain_name.to_string d ^ "/"
let manifests d = domain_prefix d ^ "manifests/"
let chunks d = domain_prefix d ^ "chunks/"
let chunks_from d = domain_prefix d ^ "chunks.from/"
let versions d = domain_prefix d ^ "versions/"
let journal d = domain_prefix d ^ "journal/"
let cursor d = domain_prefix d ^ "cursor"
let gc_run d = domain_prefix d ^ "gc-run"
let gc_generation d = domain_prefix d ^ "gc-generation"
let gc_lock d = domain_prefix d ^ "gc-run.lock"
let corrupted d = "tsync/corrupted/" ^ Domain_name.to_string d ^ "/"
let verify_jobs d = "tsync/verify-jobs/" ^ Domain_name.to_string d ^ "/"
let gc_jobs d = "tsync/gc-jobs/" ^ Domain_name.to_string d ^ "/"
let shares = "tsync/shares/"
let share_cache = "tsync/shares/cache/"

let share token =
  if token <> "" && Names.valid_leaf token then Some (shares ^ token) else None

let shard_prefix d sss = chunks d ^ sss ^ "/"
let chunk d k = chunks d ^ Chunk_key.shard k ^ "/" ^ Chunk_key.to_string k

let chunk_from d k =
  chunks_from d ^ Chunk_key.shard k ^ "/" ^ Chunk_key.to_string k

let namespace d id = manifests d ^ Folder_id.to_string id ^ "/"
let child d id leaf = namespace d id ^ Xxh.dual leaf
let anchor d id = namespace d id ^ ".tsync-parent"
let index d id = namespace d id ^ ".tsync-index"
let trash_entry d r = namespace d Folder_id.trash ^ r
let version d ~group ~ns = versions d ^ group ^ "/" ^ Printf.sprintf "%Ld" ns
let journal_entry d ~month ~entry = journal d ^ month ^ "/" ^ entry
let verify_job d sss = verify_jobs d ^ sss
let discard_job d ~run ~shard = gc_jobs d ^ run ^ "/" ^ shard
let marker d k = corrupted d ^ Chunk_key.shard k ^ "/" ^ Chunk_key.to_string k
let roots d = [domain_prefix d; corrupted d; verify_jobs d; gc_jobs d]

let split_last s =
  match String.rindex_opt s '/' with
    | None -> ("", s)
    | Some i ->
        (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))

let leaf k = snd (split_last k)
let parent_segment k = leaf (fst (split_last k))

(* Domain names hold no '/', so the second segment is always the domain. *)
let area k =
  match String.split_on_char '/' k with
    | "tsync" :: d :: area :: rest -> (
        match Domain_name.of_string d with
          | Ok d -> Some (d, area, rest)
          | Error _ -> None)
    | _ -> None

let chunk_in space k =
  match area k with
    | Some (d, a, [sss; leaf]) when a = space -> (
        match Chunk_key.of_string leaf with
          | Some c when Chunk_key.shard c = sss -> Some (d, c)
          | _ -> None)
    | _ -> None

let chunk_parts k = chunk_in "chunks" k
let chunk_of k = Option.map snd (chunk_parts k)
let outgoing_chunk k = chunk_in "chunks.from" k

let is_outgoing k =
  match area k with Some (_, "chunks.from", _) -> true | _ -> false

(* The sentinel makes the prefix end inside the space, even at its root. *)
let outgoing_prefix p =
  match area (p ^ "x") with
    | Some (d, "chunks", rest) ->
        let rest = String.concat "/" rest in
        Some (chunks_from d ^ String.sub rest 0 (String.length rest - 1))
    | _ -> None

let domain_of_reference k =
  match area k with
    | Some (d, ("manifests" | "versions"), _) -> Some d
    | _ -> None

let marker_of k = Option.map (fun (d, c) -> marker d c) (chunk_parts k)

let chunk_of_marker k =
  match String.split_on_char '/' k with
    | ["tsync"; "corrupted"; d; sss; leaf] -> (
        match (Domain_name.of_string d, Chunk_key.of_string leaf) with
          | Ok d, Some c when Chunk_key.shard c = sss -> Some (d, c)
          | _ -> None)
    | _ -> None

let after p k =
  if String.starts_with ~prefix:p k then
    Some (String.sub k (String.length p) (String.length k - String.length p))
  else None

let parse_verify_job k =
  match after "tsync/verify-jobs/" k with
    | None -> None
    | Some rest -> (
        let d, sss = split_last rest in
        match Domain_name.of_string d with
          | Ok d when Names.valid_shard sss -> Some (d, sss)
          | _ -> None)

let parse_discard_job k =
  match after "tsync/gc-jobs/" k with
    | None -> None
    | Some rest -> (
        let rest', shard = split_last rest in
        let d, run = split_last rest' in
        match Domain_name.of_string d with
          | Ok d when run <> "" && Names.valid_shard shard ->
              Some (d, run, shard)
          | _ -> None)

let is_internal_leaf leaf = String.starts_with ~prefix:".tsync-" leaf

let is_child_of ~namespace k =
  match after namespace k with
    | Some rest ->
        rest <> ""
        && (not (String.contains rest '/'))
        && not (is_internal_leaf rest)
    | None -> false

let folder_of_namespace_key d k =
  match after (manifests d) k with
    | Some rest -> (
        match String.index_opt rest '/' with
          | Some i -> Folder_id.of_string (String.sub rest 0 i)
          | None -> None)
    | None -> None

let run_name started = Printf.sprintf "%013.0f" (Float.round (started *. 1000.))
