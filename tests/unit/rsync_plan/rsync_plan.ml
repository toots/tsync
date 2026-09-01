(* What a copy decides to do about one entry, for every pairing of ends.

   Every line carries what the decision would move beside the decision itself,
   because the verdict alone reads as plausible whatever it says: the whole
   point of the command is that a file already in the domain costs nothing, and
   a snapshot of verdicts nobody priced would pin a full re-upload as happily as
   a publish. *)

let mtime = 1000.
let chunk_key n = Printf.sprintf "%016x-%016x" n n

let manifest ?(name = "f") ?(chunk_size = 8) keys =
  let count = List.length keys in
  let size = Int64.of_int (count * chunk_size) in
  let key i = List.nth keys i in
  let len i = Chunks.length_of ~size ~chunk_size i in
  let h1, h2 = Manifest.digest_of_keys ~count ~key ~len in
  Manifest.of_string
    (Manifest.encode ~name ~size ~chunk_size ~mtime ~h1 ~h2 ~symlink:None ~keys)

let symlink target = Manifest.make_symlink ~name:"l" ~target ~mtime

let local ?keys ?link ?(size = 24L) ?(mtime = mtime) () =
  { Rsync.size; mtime; keys; link }

(* What the decision would put on the wire, which is the property the command
   exists to hold down. *)
let cost = function
  | Rsync.Skip _ | Rsync.Make_dir _ | Rsync.Rename_in_domain -> "0 bytes"
  | Rsync.Copy_manifest m ->
      Printf.sprintf "0 bytes, %d chunks named" (Manifest.count m)
  | Rsync.Upload _ -> "the whole file"
  | Rsync.Assemble m -> Printf.sprintf "%Ld bytes" (Manifest.size m)
  | Rsync.Patch_local { src; chunks } ->
      Printf.sprintf "%d bytes"
        (List.length chunks * Manifest.chunk_size src)

let show = function
  | Rsync.Skip `Source_missing -> "skip source-missing"
  | Rsync.Skip `Identical -> "skip identical"
  | Rsync.Skip `Target_is_dir -> "skip target-is-dir"
  | Rsync.Skip `Target_not_a_dir -> "skip target-not-a-dir"
  | Rsync.Skip `Not_in_domain -> "skip not-in-domain"
  | Rsync.Make_dir `Domain -> "make-dir domain"
  | Rsync.Make_dir `Local -> "make-dir local"
  | Rsync.Rename_in_domain -> "rename-in-domain"
  | Rsync.Copy_manifest _ -> "copy-manifest"
  | Rsync.Upload `Fresh -> "upload fresh"
  | Rsync.Upload `Replacing -> "upload replacing"
  | Rsync.Assemble _ -> "assemble"
  | Rsync.Patch_local { chunks; _ } ->
      "patch-local ["
      ^ String.concat ";" (List.map string_of_int chunks)
      ^ "]"

(* Which constructors a run reached, so a case added to the type and driven by
   nothing fails the roll-call rather than passing unnoticed. *)
let reached = Hashtbl.create 16

let tag = function
  | Rsync.Skip s -> (
      match s with
        | `Source_missing -> "skip-source-missing"
        | `Identical -> "skip-identical"
        | `Target_is_dir -> "skip-target-is-dir"
        | `Target_not_a_dir -> "skip-target-not-a-dir"
        | `Not_in_domain -> "skip-not-in-domain")
  | Rsync.Make_dir _ -> "make-dir"
  | Rsync.Rename_in_domain -> "rename-in-domain"
  | Rsync.Copy_manifest _ -> "copy-manifest"
  | Rsync.Upload _ -> "upload"
  | Rsync.Assemble _ -> "assemble"
  | Rsync.Patch_local _ -> "patch-local"

let decided ?(move = false) name ~src target =
  let d = Rsync.decide ~move ~src target in
  Hashtbl.replace reached (tag d) ();
  let disposal =
    match Rsync.source_disposal ~move d with
      | `Keep -> ""
      | `Drop -> ", source dropped"
  in
  Check.step "%-32s -> %-22s (%s%s)" name (show d) (cost d) disposal

let outcomes =
  [
    "skip-source-missing";
    "skip-identical";
    "skip-target-is-dir";
    "skip-target-not-a-dir";
    "skip-not-in-domain";
    "make-dir";
    "rename-in-domain";
    "copy-manifest";
    "upload";
    "assemble";
    "patch-local";
  ]

let () =
  let three = [ chunk_key 1; chunk_key 2; chunk_key 3 ] in
  let src = manifest three in
  let other = manifest [ chunk_key 1; chunk_key 9; chunk_key 3 ] in

  Check.case "either end missing or the wrong kind";
  decided "source gone" ~src:`Missing (`Absent `Domain);
  decided "dir onto nothing" ~src:`Dir (`Absent `Domain);
  decided "dir onto nothing, local" ~src:`Dir (`Absent `Local);
  decided "dir onto a dir" ~src:`Dir (`Dir `Domain);
  decided "dir onto a file" ~src:`Dir (`Key src);
  decided "file onto a dir" ~src:(`Key src) (`Dir `Domain);

  Check.case "domain -> domain";
  decided "target absent" ~src:(`Key src) (`Absent `Domain);
  decided "target absent, --move" ~move:true ~src:(`Key src) (`Absent `Domain);
  decided "same chunk list" ~src:(`Key src) (`Key (manifest three));
  decided "differing chunk list" ~src:(`Key src) (`Key other);
  decided "differing, --move" ~move:true ~src:(`Key src) (`Key other);
  decided "chunk size differs" ~src:(`Key src)
    (`Key (manifest ~chunk_size:16 three));
  decided "same symlink" ~src:(`Key (symlink "a")) (`Key (symlink "a"));
  decided "two symlinks, one target each"
    ~src:(`Key (symlink "a"))
    (`Key (symlink "b"));

  Check.case "local -> domain";
  decided "target absent" ~src:(`File (local ())) (`Absent `Domain);
  decided "size and mtime agree" ~src:(`File (local ())) (`Key src);
  decided "size differs" ~src:(`File (local ~size:99L ())) (`Key src);
  decided "mtime differs" ~src:(`File (local ~mtime:1. ())) (`Key src);
  decided "hashed, keys agree"
    ~src:(`File (local ~keys:(Array.of_list three) ()))
    (`Key src);
  decided "hashed, keys differ"
    ~src:(`File (local ~keys:[| chunk_key 1; chunk_key 9; chunk_key 3 |] ()))
    (`Key src);

  Check.case "domain -> local";
  decided "target absent" ~src:(`Key src) (`Absent `Local);
  decided "not hashed" ~src:(`Key src) (`File (local ()));
  decided "hashed, all match"
    ~src:(`Key src)
    (`File (local ~keys:(Array.of_list three) ()));
  decided "hashed, two differ"
    ~src:(`Key src)
    (`File
       (local ~keys:[| chunk_key 1; chunk_key 8; chunk_key 7 |] ()));
  decided "hashed at another size"
    ~src:(`Key src)
    (`File (local ~keys:[| chunk_key 1; chunk_key 2 |] ()));

  Check.case "links, compared by what they point at";
  decided "the same target" ~src:(`Key (symlink "a"))
    (`File (local ~link:"a" ~size:1L ()));
  decided "another target" ~src:(`Key (symlink "a"))
    (`File (local ~link:"b" ~size:1L ()));
  decided "a link where a file is published" ~src:(`Key src)
    (`File (local ~link:"a" ~size:1L ()));
  decided "a file where a link is published" ~src:(`Key (symlink "a"))
    (`File (local ()));

  Check.case "neither end in a domain";
  decided "onto nothing" ~src:(`File (local ())) (`Absent `Local);
  decided "onto a file" ~src:(`File (local ())) (`File (local ()));

  Check.case "every decision the type can return is reached";
  List.iter
    (fun name ->
      Check.check
        (Printf.sprintf "  %s" name)
        (Hashtbl.mem reached name))
    outcomes;
  Check.report ~expected:(List.length outcomes) ()
