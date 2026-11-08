open Tsync_core

type side = Local | Domain
type local = Link of string | Hashed of Chunk_key.t list | Unhashed
type source = Missing | Dir | File of local * Fs.times | Key of Manifest.t

type target =
  | Absent of side
  | Dir_at of side
  | File_at of local * Fs.times
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
  | Retime_in_domain of Manifest.t
  | Retime_local of Fs.times
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

(* 02 §2.6: the same content with other times is a change of times. A local
   target holds times only as finely as its filesystem, export's slack, and a
   creation time only where one can be set. *)
let near (a : Fs.times) (b : Fs.times) =
  abs (a.mtime - b.mtime) <= Export.mtime_slack
  && ((not Fs.sets_created) || abs (a.created - b.created) <= Export.mtime_slack)

(* What an install will hold, carried over [d] (02 §2.6). *)
let into_domain (d : Manifest.t) times =
  let times = Fs.carried_over ~held:(Manifest.times d) times in
  if Manifest.times d = times then Identical
  else Retime_in_domain (Manifest.with_times d times)

let onto_local local (m : Manifest.t) =
  if near local (Manifest.times m) then Identical
  else Retime_local (Manifest.times m)

let decide ~move source target =
  match (source, target) with
    | Missing, _ -> Skip Source_missing
    | Dir, (Absent s | Dir_at s) -> Make_dir s
    | Dir, (File_at _ | Key_at _) -> Skip Target_not_a_dir
    | (File _ | Key _), Dir_at _ -> Skip Target_is_dir
    | Key m, Absent Domain ->
        if move then Rename_in_domain m else Copy_manifest m
    | Key a, Key_at b ->
        if a.h1 = b.h1 then into_domain b (Manifest.times a)
        else Copy_manifest a
    | File _, Absent Domain -> Upload `Fresh
    | File (l, t), Key_at d ->
        if unchanged l d then into_domain d t else Upload `Replacing
    | Key m, Absent Local -> Assemble m
    | Key m, File_at (l, t) -> (
        match differing l m with
          | `Unknown -> if unchanged l m then onto_local t m else Assemble m
          | `Indices [] -> onto_local t m
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
  uncommitted : int;
  cancelled : bool;
}

let describe = function
  | Skip s -> "skip: " ^ skip_name s
  | Make_dir _ -> "make the folder"
  | Identical -> "identical"
  | Retime_in_domain _ | Retime_local _ -> "set its times"
  | Copy_manifest _ -> "copy within the domain"
  | Rename_in_domain _ -> "move within the domain"
  | Upload `Fresh -> "upload"
  | Upload `Replacing -> "upload, replacing"
  | Assemble _ -> "download"
  | Patch_local (_, is) ->
      Printf.sprintf "download %d differing chunks" (List.length is)
