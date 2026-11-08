(* Rsync's decision (spec 05 §4.5), row by row. *)

open Tsync_core
open Tsync_sync
open Rsync_plan

let p fmt = Printf.printf fmt
let ck s = Chunk_key.of_body s
let cs = Chunking.chunk_size_min

let file name chunks =
  Manifest.make ~name
    ~size:(List.length chunks * cs)
    ~times:{ Tsync_core.Fs.mtime = 0; created = 0 }
    ~chunk_size:cs (List.map ck chunks)

let link name target =
  Manifest.symlink ~name ~times:{ Tsync_core.Fs.mtime = 0; created = 0 } target

let t0 = { Tsync_core.Fs.mtime = 0; created = 0 }
let ab = file "f" ["a"; "b"]
let ac = file "f" ["a"; "c"]
let to_x = link "l" "x"

let show_decision = function
  | Skip s -> "skip: " ^ skip_name s
  | Make_dir Local -> "make a local folder"
  | Make_dir Domain -> "make a domain folder"
  | Identical -> "identical"
  | Retime_in_domain m ->
      Printf.sprintf "give %s the times %d, %d" m.name m.mtime m.created
  | Retime_local t ->
      Printf.sprintf "set the local times %d, %d" t.mtime t.created
  | Copy_manifest m -> "copy the manifest " ^ m.name
  | Rename_in_domain m -> "rename " ^ m.name ^ " in the domain"
  | Upload `Fresh -> "upload, fresh"
  | Upload `Replacing -> "upload, replacing"
  | Assemble m -> "assemble " ^ m.name
  | Patch_local (_, is) ->
      "patch chunks " ^ String.concat "," (List.map string_of_int is)

let row label ?(move = false) source target =
  let d = decide ~move source target in
  p "%-46s %s%s\n" label (show_decision d)
    (if disposes ~move d then "; the source is dropped" else "")

let () =
  row "missing source" Missing (Absent Domain);
  row "folder to nothing in the domain" Dir (Absent Domain);
  row "folder to a local folder" Dir (Dir_at Local);
  row "folder onto a local file" Dir (File_at (Unhashed, t0));
  row "folder onto a domain file" Dir (Key_at ab);
  row "domain file onto a local folder" (Key ab) (Dir_at Local);
  row "local file onto a domain folder" (File (Unhashed, t0)) (Dir_at Domain);
  row "domain file to nothing in the domain" (Key ab) (Absent Domain);
  row "domain file to nothing, moved" ~move:true (Key ab) (Absent Domain);
  row "domain file onto the same content" (Key ab)
    (Key_at (file "g" ["a"; "b"]));
  row "domain file onto other content" (Key ab) (Key_at ac);
  row "domain file onto the same content, moved" ~move:true (Key ab)
    (Key_at (file "g" ["a"; "b"]));
  row "local file to nothing in the domain"
    (File (Unhashed, t0))
    (Absent Domain);
  row "local file equal to the domain's"
    (File (Hashed [ck "a"; ck "b"], t0))
    (Key_at ab);
  row "local file differing from the domain's"
    (File (Hashed [ck "a"; ck "z"], t0))
    (Key_at ab);
  row "unhashed local file onto a domain file" (File (Unhashed, t0)) (Key_at ab);
  row "local link equal to the domain's" (File (Link "x", t0)) (Key_at to_x);
  row "local link onto a domain file" (File (Link "x", t0)) (Key_at ab);
  row "domain file to nothing locally" (Key ab) (Absent Local);
  row "domain file onto an equal local file" (Key ab)
    (File_at (Hashed [ck "a"; ck "b"], t0));
  row "domain file onto a local file, one chunk off" (Key ab)
    (File_at (Hashed [ck "a"; ck "z"], t0));
  row "domain file onto a shorter local file" (Key ab)
    (File_at (Hashed [ck "a"], t0));
  row "domain link onto the same local link" (Key to_x) (File_at (Link "x", t0));
  row "domain link onto another local link" (Key to_x) (File_at (Link "y", t0));
  row "domain file onto an unhashed local file" (Key ab)
    (File_at (Unhashed, t0));
  row "local file to nothing locally" (File (Unhashed, t0)) (Absent Local);
  row "local file onto a local file"
    (File (Unhashed, t0))
    (File_at (Unhashed, t0));
  row "local file to the domain, moved" ~move:true
    (File (Unhashed, t0))
    (Absent Domain);
  let at s =
    { Tsync_core.Fs.mtime = s * 1_000_000_000; created = s * 1_000_000_000 }
  in
  let timed t m = Manifest.with_times m t in
  row "local file equal to the domain's, other times"
    (File (Hashed [ck "a"; ck "b"], at 7))
    (Key_at ab);
  row "domain file onto the same content, other times"
    (Key (timed (at 7) ab))
    (Key_at (file "g" ["a"; "b"]));
  row "domain file, the target created earlier"
    (Key (timed { (at 7) with created = 9_000_000_000 } ab))
    (Key_at
       (timed { (at 7) with created = 3_000_000_000 } (file "g" ["a"; "b"])));
  row "domain file onto an equal local file, 1 s apart"
    (Key (timed (at 7) ab))
    (File_at (Hashed [ck "a"; ck "b"], at 8));
  row "domain file onto an equal local file, 9 s apart"
    (Key (timed (at 7) ab))
    (File_at (Hashed [ck "a"; ck "b"], at 16));
  row "folder, moved" ~move:true Dir (Absent Domain)
