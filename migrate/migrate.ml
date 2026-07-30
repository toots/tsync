(* Re-shard a backend store into the current layout: chunks by {!Chunk_layout},
   journal entries by {!Journal.relative_path}.

   One-shot, run by hand against a local-disk backend. Idempotent: a file already
   at its target path is left alone, so a second run is a no-op and an
   interrupted run resumes. The cache's chunk store works too — the placement
   only ever looks at a file's own name.

   Usage: migrate [--journal] [--verbose] <dir> [<dir>...] *)

(* What a store holds, and where it belongs. *)
type kind = {
  noun : string;
  valid : string -> bool;  (** is this filename one of ours? *)
  place : string -> string;  (** its path relative to the store root *)
}

let is_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
let is_digit c = c >= '0' && c <= '9'

let chunks =
  {
    noun = "chunk";
    (* "<16 hex>-<16 hex>" *)
    valid =
      (fun name ->
        String.length name = 33
        && name.[16] = '-'
        && String.for_all (fun c -> is_hex c || c = '-') name);
    place = Chunk_layout.relative_path;
  }

let journal =
  {
    noun = "journal entry";
    (* "<13-digit ms>-<client uuid>". The length check is what keeps a month
       shard directory ("2026-07") from looking like an entry. *)
    valid =
      (fun name ->
        String.length name > 14
        && name.[13] = '-'
        && String.for_all is_digit (String.sub name 0 13));
    place = Journal.relative_path;
  }

(* Names are collected with the directory closed before anything is renamed —
   mutating a directory under an open readdir cursor has unspecified results.
   The bound keeps the name list small on a store whose files are all in one
   directory; a scan that fills it just runs again, and the entries it already
   moved are gone by then. *)
let batch_size = 10_000
let moved = ref 0
let placed = ref 0
let dropped = ref 0
let skipped = ref 0
let verbose = ref false
let shards : (string, unit) Hashtbl.t = Hashtbl.create 4096

(* Every rename, one line. Buffered: a store with millions of chunks would spend
   more time on the terminal than on the disk if each line were flushed. *)
let say fmt = if !verbose then Printf.printf fmt else Printf.ifprintf stdout fmt

let ensure_shard path =
  let dir = Filename.dirname path in
  if not (Hashtbl.mem shards dir) then (
    (try
       Unix.mkdir dir 0o755;
       say "  mkdir %s\n" dir
     with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    Hashtbl.replace shards dir ())

let size path = (Unix.stat path).Unix.st_size

let move (src, dst) =
  if Sys.file_exists dst then
    (* Both stores name a file after its content or its identity, so a source
       whose target exists is a duplicate of it — unless the sizes disagree,
       which means one of the two is not what its name says. *)
    if size src = size dst then (
      Unix.unlink src;
      say "  drop %s (duplicate of %s)\n" src dst;
      incr dropped)
    else (
      Printf.eprintf "size mismatch, left in place: %s\n" src;
      incr skipped)
  else (
    ensure_shard dst;
    Unix.rename src dst;
    say "  move %s -> %s\n" src dst;
    incr moved;
    if !moved mod 50_000 = 0 then (
      Printf.printf "  %d moved...\n" !moved;
      flush stdout))

(* One scan of [dir]: up to [batch_size] files that have somewhere else to go, as
   (source, target) pairs, plus every other entry as a candidate subdirectory.
   Also reports how many files are already where they belong. Returns [true] when
   the bound was hit.

   A file already at its target is deliberately not a candidate: it never leaves
   [dir], so counting it toward the batch would let a full batch move nothing and
   the rescan loop spin forever. *)
let scan ~kind ~root dir others =
  let d = Unix.opendir dir in
  let batch = ref [] and n = ref 0 and here = ref 0 in
  (try
     while !n < batch_size do
       let name = Unix.readdir d in
       if name = Filename.current_dir_name || name = Filename.parent_dir_name
       then ()
       else if not (kind.valid name) then Hashtbl.replace others name ()
       else (
         let src = Filename.concat dir name
         and dst = Filename.concat root (kind.place name) in
         if src = dst then incr here
         else (
           batch := (src, dst) :: !batch;
           incr n))
     done
   with End_of_file -> ());
  Unix.closedir d;
  (!batch, !here, !n >= batch_size)

let rec migrate_dir ~kind ~root dir =
  let others = Hashtbl.create 16 in
  say "scan %s\n" dir;
  let rec passes () =
    let batch, here, more = scan ~kind ~root dir others in
    say "  pass: %d to move, %d already placed%s\n" (List.length batch) here
      (if more then ", more to come" else "");
    List.iter move batch;
    (* Placed files are counted on the final pass only — they are exactly the
       ones every pass sees, so any earlier count would be a duplicate. Which is
       also why they get no line of their own: it would repeat every pass. *)
    if more then passes () else placed := !placed + here
  in
  passes ();
  Hashtbl.iter
    (fun name () ->
      let path = Filename.concat dir name in
      if Hashtbl.mem shards path then
        (* A shard this run filled: everything in it was just put there. *)
        ()
      else if try Sys.is_directory path with Sys_error _ -> false then (
        migrate_dir ~kind ~root path;
        (* Emptied by the move — an old shard directory, or one this run created
           and then found nothing for. Fails harmlessly otherwise. *)
        try
          Unix.rmdir path;
          say "  rmdir %s\n" path
        with Unix.Unix_error _ -> ())
      else (
        Printf.eprintf "not a %s, skipped: %s\n" kind.noun path;
        incr skipped))
    others

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let kind = if List.mem "--journal" args then journal else chunks in
  verbose := List.mem "--verbose" args || List.mem "-v" args;
  let dirs =
    List.filter
      (fun a -> not (List.mem a ["--journal"; "--verbose"; "-v"]))
      args
  in
  if dirs = [] then (
    prerr_endline "usage: migrate [--journal] [--verbose] <dir> [<dir>...]";
    exit 2);
  List.iter
    (fun dir ->
      let root =
        let l = String.length dir in
        if l > 1 && dir.[l - 1] = '/' then String.sub dir 0 (l - 1) else dir
      in
      Printf.printf "%s\n%!" root;
      migrate_dir ~kind ~root root)
    dirs;
  Printf.printf
    "moved %d, already placed %d, duplicates dropped %d, skipped %d\n" !moved
    !placed !dropped !skipped
