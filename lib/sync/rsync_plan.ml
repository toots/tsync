open Tsync_core

type side = Local | Domain
type local = Link of string | Hashed of Chunk_key.t list | Unhashed
type source = Missing | Dir | File of local | Key of Manifest.t

type target =
  | Absent of side
  | Dir_at of side
  | File_at of local
  | Key_at of Manifest.t

type skip =
  | Source_missing
  | Target_not_a_dir
  | Target_is_dir
  | Not_in_domain
  | Under_skipped
  | Unpublished

type decision =
  | Skip of skip
  | Make_dir of side
  | Identical
  | Copy_manifest of Manifest.t
  | Rename_in_domain of Manifest.t
  | Upload of [ `Fresh | `Replacing ]
  | Assemble of Manifest.t
  | Patch_local of Manifest.t * int list

let keys (m : Manifest.t) = List.init m.count (Manifest.key m)

let unchanged local (m : Manifest.t) =
  match (local, m.link) with
    | Link t, Some t' -> t = t'
    | Hashed ks, None ->
        List.length ks = m.count && List.for_all2 Chunk_key.equal ks (keys m)
    | _ -> false

let differing local (m : Manifest.t) =
  match (local, m.link) with
    | Hashed ks, None when List.length ks = m.count ->
        `Indices
          (List.filteri
             (fun _ i -> i >= 0)
             (List.mapi
                (fun i (a, b) -> if Chunk_key.equal a b then -1 else i)
                (List.combine ks (keys m))))
    | _ -> `Unknown

let decide ~move source target =
  match (source, target) with
    | Missing, _ -> Skip Source_missing
    | Dir, (Absent s | Dir_at s) -> Make_dir s
    | Dir, (File_at _ | Key_at _) -> Skip Target_not_a_dir
    | (File _ | Key _), Dir_at _ -> Skip Target_is_dir
    | Key m, Absent Domain ->
        if move then Rename_in_domain m else Copy_manifest m
    | Key a, Key_at b -> if a.h1 = b.h1 then Identical else Copy_manifest a
    | File _, Absent Domain -> Upload `Fresh
    | File l, Key_at d -> if unchanged l d then Identical else Upload `Replacing
    | Key m, Absent Local -> Assemble m
    | Key m, File_at l -> (
        match differing l m with
          | `Unknown -> if unchanged l m then Identical else Assemble m
          | `Indices [] -> Identical
          | `Indices is -> Patch_local (m, is))
    | File _, (Absent Local | File_at _) -> Skip Not_in_domain

let disposes ~move = function
  | Skip _ | Rename_in_domain _ | Make_dir _ -> false
  | _ -> move

let skip_name = function
  | Source_missing -> "the source is missing"
  | Target_not_a_dir -> "a file holds the folder's name at the target"
  | Target_is_dir -> "a folder holds the file's name at the target"
  | Not_in_domain -> "neither side is in the domain"
  | Under_skipped -> "its folder was skipped"
  | Unpublished -> "this client's edit of it is not published yet"

type endpoint = { side : side; path : string }

type report = {
  copied : int;
  identical : int;
  skipped : (string * string) list;
  dirs : int;
  failed : (string * string) list;
  bytes_moved : int;
  planned : (string * decision) list;
  unpublished : string list;
  cancelled : bool;
}

let describe = function
  | Skip s -> "skip: " ^ skip_name s
  | Make_dir _ -> "make the folder"
  | Identical -> "identical"
  | Copy_manifest _ -> "copy within the domain"
  | Rename_in_domain _ -> "move within the domain"
  | Upload `Fresh -> "upload"
  | Upload `Replacing -> "upload, replacing"
  | Assemble _ -> "download"
  | Patch_local (_, is) ->
      Printf.sprintf "download %d differing chunks" (List.length is)
