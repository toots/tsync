(* The import plan (spec 05 §4.3 step 2) over a real directory: order, exclude,
   only with folders planned lazily, empty folders, links by policy, and an
   unreadable directory. *)

open Tsync_core
open Tsync_sync

let p fmt = Printf.printf fmt

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-import-plan-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  let src = Filename.concat root "src" in
  let file rel body =
    let path = Filename.concat src rel in
    Fs.mkdir_p (Filename.dirname path);
    Out_channel.with_open_bin path (fun oc -> output_string oc body)
  in
  let dir rel = Fs.mkdir_p (Filename.concat src rel) in
  file "a.txt" "1";
  file "a b" "22";
  file "a/x.txt" "333";
  file "a/deep/y.ml" "4444";
  file "photos/2026/p.jpg" "55555";
  file "photos/notes.txt" "6";
  file ".git/config" "7";
  file "sub/.git/HEAD" "8";
  dir "empty";
  Unix.symlink "a/x.txt" (Filename.concat src "link");
  Unix.symlink "nowhere" (Filename.concat src "dangling");
  Unix.symlink "photos" (Filename.concat src "photos-link");
  dir "locked";
  file "locked/hidden" "9";
  Unix.chmod (Filename.concat src "locked") 0;
  let show label ?only ?exclude symlinks =
    let plan = Import_plan.plan ?only ?exclude ~symlinks src in
    p "== %s: %d files, %d bytes\n" label plan.files plan.bytes;
    List.iter
      (function
        | Import_plan.Folder r -> p "  folder %s\n" r
        | File { rel; size; _ } -> p "  file   %s (%d)\n" rel size
        | Link { rel; target; size; _ } ->
            p "  link   %s -> %s (%d)\n" rel target size)
      plan.entries;
    (* Unreadable folders are named by their resolved path, and /tmp is a
       symbolic link on macOS. *)
    let real = Unix.realpath src in
    List.iter
      (fun d ->
        p "  unreadable %s\n"
          (String.sub d
             (String.length real + 1)
             (String.length d - String.length real - 1)))
      plan.unreadable
  in
  show "everything, links kept" `Keep;
  show "excluding **/.git and every *.txt by basename"
    ~exclude:["**/.git"; "*.txt"] `Skip;
  show "only photos/** and **/*.ml, links followed"
    ~only:["photos/**"; "**/*.ml"] `Follow;
  Unix.chmod (Filename.concat src "locked") 0o755;
  Fs.rm_rf root
