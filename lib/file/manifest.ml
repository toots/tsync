(* A published file's metadata: name, size, mtime and the ordered keys of the
   chunks holding its bytes.

   The body is a {!Chunk_table} — a fixed header followed by a flat run of chunk
   keys, mapped rather than parsed. Header fields are lifted into this record;
   the table stays in the mapping and is authoritative for the chunks. A 32 GB
   file at 1 MiB chunks is 31,230 keys nobody materializes to answer "what is
   this file called?". *)

type t = {
  name : string;  (** leaf name; authority for the file's own name *)
  size : int64;
  chunk_size : int;
  chunks : Chunk_table.t;
  h1 : string;
  h2 : string;
  mtime : float;
  symlink : string option;
}

(* What an upload produces per chunk. Read paths go through the table. *)
type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

let chunk_key (entry : chunk_entry) = entry.h1 ^ "-" ^ entry.h2

(* The reverse, for a chunk kept from a previous upload: only its key was held
   onto, and the two digests are its halves. *)
let entry_of_key ~index ~size key =
  match String.index_opt key '-' with
    | Some i ->
        {
          index;
          h1 = String.sub key 0 i;
          h2 = String.sub key (i + 1) (String.length key - i - 1);
          size;
        }
    | None -> invalid_arg ("Manifest.entry_of_key: " ^ key)

(* How a file's stored chunks fall into cache chunks. Derived from the file's
   {i own} chunk size, so a file uploaded under a different setting still groups
   correctly. {!Chunk_group} sits below this module and cannot host it. *)

let per ~cache_chunk_size (m : t) =
  Chunk_group.per_group ~chunk_size:m.chunk_size ~cache_chunk_size

let groups ~cache_chunk_size m =
  Chunk_group.all ~table:m.chunks ~per:(per ~cache_chunk_size m)

let group_at ~cache_chunk_size m i =
  Chunk_group.of_table ~table:m.chunks ~per:(per ~cache_chunk_size m) i

let group_count ~cache_chunk_size m =
  Chunk_group.count ~table:m.chunks ~per:(per ~cache_chunk_size m)

(* Hashed over the ordered chunk digests, so a changed file's manifest rebuilds
   from its chunk entries without re-reading untouched bytes. Seeds 0/1 give the
   two independent hashes. *)
let digest_of_chunks chunks =
  let s1 = Xxhash.create 0 and s2 = Xxhash.create 1 in
  List.iter
    (fun (c : chunk_entry) ->
      let d = Printf.sprintf "%s-%s-%d;" c.h1 c.h2 c.size in
      Xxhash.update s1 d;
      Xxhash.update s2 d)
    chunks;
  (Xxhash.digest_hex s1, Xxhash.digest_hex s2)

let of_table chunks =
  {
    name = Chunk_table.name chunks;
    size = Chunk_table.size chunks;
    chunk_size = Chunk_table.chunk_size chunks;
    chunks;
    h1 = Chunk_table.h1 chunks;
    h2 = Chunk_table.h2 chunks;
    mtime = Chunk_table.mtime chunks;
    symlink = Chunk_table.symlink chunks;
  }

let of_string s = of_table (Chunk_table.of_string s)

(* Mapped: chunk keys cost no heap and the pages are reclaimable. *)
let of_file path = of_table (Chunk_table.of_file path)

let to_string (m : t) =
  Chunk_table.encode ~name:m.name ~size:m.size ~chunk_size:m.chunk_size
    ~mtime:m.mtime ~h1:m.h1 ~h2:m.h2 ~symlink:m.symlink
    ~keys:(List.init (Chunk_table.count m.chunks) (Chunk_table.key m.chunks))

(* Encode then decode, so a [t] only ever exists as a decoded body and cannot
   fail to round-trip. *)
let make ~name ~h1 ~h2 ~size ~chunk_size ~chunks ~mtime =
  of_string
    (Chunk_table.encode ~name ~size ~chunk_size ~mtime ~h1 ~h2 ~symlink:None
       ~keys:(List.map chunk_key chunks))

(* A chunkless manifest carrying its target; POSIX size is the target's byte
   length. *)
let make_symlink ~name ~target ~mtime =
  of_string
    (Chunk_table.encode ~name
       ~size:(Int64.of_int (String.length target))
         (* No chunks to group; the domain default keeps the field
            well-formed. *)
       ~chunk_size:Conf.default_chunk_size ~mtime ~h1:(Xxhash.hash_hex target 0)
       ~h2:(Xxhash.hash_hex target 1) ~symlink:(Some target) ~keys:[])

(* A file with unsynced local edits has a staged manifest recording, per chunk,
   where its bytes are: a staged body of its own, inherited from the published
   manifest, or nothing (a hole from a grow, reading as zeros and needing no
   disk).

   [size] is authoritative rather than derived from a file length, so a truncate
   either way is a metadata write plus at most one boundary fixup.

   A staged manifest on disk means an upload is owed. Once [published] is set the
   upload has happened, and the staged manifest is the commit record of a
   promotion to replay rather than re-upload. *)

type slot =
  | Staged of string  (** body at [staged/chunks/<uuid>] *)
  | Inherit  (** the published manifest's entry at this index *)
  | Zero  (** never written; reads as zeros *)

type staged = {
  s_name : string;
  s_size : int64;
  s_mtime : float;
  s_chunk_size : int;
  s_slots : slot array;
  s_whole : string option;
      (** A whole file handed over by a frontend: its bytes are one file rather
          than per-chunk bodies, [s_slots] is empty, and the upload needs no
          chunking pass. *)
  s_published : t option;
}

let num_chunks_for size chunk_size =
  let s = Int64.to_int size in
  if s <= 0 then 0 else (s + chunk_size - 1) / chunk_size

(* Bytes chunk [i] holds in a file of [size] at [chunk_size]. *)
let chunk_len ~size ~chunk_size i =
  max 0 (min chunk_size (Int64.to_int size - (i * chunk_size)))

let new_uuid = Id.short

let slot_to_json = function
  | Staged uuid -> `Assoc [("u", `String uuid)]
  | Inherit -> `Assoc []
  | Zero -> `Assoc [("z", `Bool true)]

let slot_of_json j =
  let open Yojson.Basic.Util in
  match j |> member "u" with
    | `String uuid -> Staged uuid
    | _ -> ( match j |> member "z" with `Bool true -> Zero | _ -> Inherit)

let staged_to_string (st : staged) =
  Yojson.Basic.to_string
    (`Assoc
       ([
          ("v", `Int 1);
          ("name", `String st.s_name);
          ("size", `Int (Int64.to_int st.s_size));
          ("mtime", `Float st.s_mtime);
          ("chunkSize", `Int st.s_chunk_size);
        ]
       @ (match st.s_whole with
         | Some uuid -> [("whole", `String uuid)]
         | None ->
             [
               ( "slots",
                 `List (Array.to_list (Array.map slot_to_json st.s_slots)) );
             ])
       @
         match st.s_published with
         | None -> []
         (* The published body is binary; base64 keeps it inside this JSON rather
            than in a second file that would have to move atomically with it. *)
         | Some m ->
             [("published", `String (Base64.encode_string (to_string m)))]))

let staged_of_string body =
  let open Yojson.Basic.Util in
  let json = Yojson.Basic.from_string body in
  let published =
    match json |> member "published" with
      | `String b64 -> (
          match of_string (Base64.decode_exn b64) with
            | m -> Some m
            | exception _ -> None)
      | _ -> None
  in
  let whole =
    match json |> member "whole" with `String u -> Some u | _ -> None
  in
  {
    s_name = json |> member "name" |> to_string;
    s_size = json |> member "size" |> to_int |> Int64.of_int;
    s_mtime = json |> member "mtime" |> to_float;
    s_chunk_size =
      (try json |> member "chunkSize" |> to_int
       with _ -> Conf.default_chunk_size);
    s_slots =
      (match json |> member "slots" with
        | `List l -> Array.of_list (List.map slot_of_json l)
        | _ -> [||]);
    s_whole = whole;
    s_published = published;
  }

(* Everything about where a manifest lives and how the tree is walked is below,
   so callers only name logical keys. The tree mirrors real paths: directories
   are real directories (a name the filesystem cannot hold verbatim becomes an
   escaped handle plus a marker file with the real name), and a file's
   authoritative name is the [name] in its own body, never the on-disk one. *)

open Lwt.Syntax

let dir ~cache_root domain_name =
  Cache_layout.manifests_dir ~cache_root domain_name

let sidecar_path ~cache_root ~domain_name ~domain_prefix key =
  Filename.concat
    (dir ~cache_root domain_name)
    (Name_escape.encode_key (Key.strip_prefix ~domain_prefix key))

let staged_sidecar_path ~cache_root ~domain_name ~domain_prefix key =
  Filename.concat
    (Cache_layout.staged_manifests_dir ~cache_root domain_name)
    (Name_escape.encode_key (Key.strip_prefix ~domain_prefix key))

(* Synchronous, for the CLI listing (plain non-Lwt code). Unsynced edits are
   local by definition; otherwise every chunk the sidecar names must be in the
   chunk store.
   ponytail: a bool, so a partly cached file reads as remote. Return the chunk
   counts here if `tsync ls` should distinguish "partial n/m". *)
let is_local
    ({ Conf.cache_root; domain_name; domain_prefix; cache_chunk_size } :
      Conf.locality) key =
  Sys.file_exists
    (staged_sidecar_path ~cache_root ~domain_name ~domain_prefix key)
  ||
    match
      of_file (sidecar_path ~cache_root ~domain_name ~domain_prefix key)
    with
    | m ->
        List.for_all
          (fun g ->
            Sys.file_exists
              (Cache_layout.chunk_path ~cache_root ~domain_name
                 (Chunk_group.key g)))
          (groups ~cache_chunk_size m)
    | exception _ -> false

(* Records an escaped directory's real name so readdir can recover it. *)
let write_marker path name =
  let* exists = Lwt_unix_retry.file_exists path in
  if exists then Lwt.return_unit else Fs_util.atomic_write path name

let read_marker path =
  Lwt.catch
    (fun () -> Lwt_unix_retry.with_file ~mode:Lwt_io.Input path Lwt_io.read)
    (fun _ -> Lwt.return "")

(* Real name of a subdirectory: its marker when the on-disk name is escaped,
   else the on-disk name. *)
let real_dir_name dir_path name =
  if Name_escape.is_escaped name then
    read_marker (Filename.concat dir_path Name_escape.dir_marker)
  else Lwt.return name

(* Creates the directory chain for [rel], with a name marker inside each escaped
   component. *)
let ensure_dirs root rel =
  let components =
    String.split_on_char '/' rel |> List.filter (fun c -> c <> "")
  in
  let* () = Fs_util.mkdir_p root in
  let rec go dir = function
    | [] -> Lwt.return_unit
    | c :: rest ->
        let enc = Name_escape.encode_component c in
        let dir = Filename.concat dir enc in
        let* () = Fs_util.mkdir_p dir in
        let* () =
          if Name_escape.is_escaped enc then
            write_marker (Filename.concat dir Name_escape.dir_marker) c
          else Lwt.return_unit
        in
        go dir rest
  in
  go root components

(* Entries the mirror keeps for itself. *)
let is_internal name =
  Filename.check_suffix name ".tmp"
  || name = Name_escape.dir_marker
  || name = Folder_ids.marker_name

let read_body path =
  Lwt.catch
    (fun () ->
      let+ s = Lwt_unix_retry.with_file ~mode:Lwt_io.Input path Lwt_io.read in
      Some s)
    (fun _ -> Lwt.return_none)

(* Mapped, not read: a listing wants name, size and mtime, and never touches the
   chunk keys. [Unix.openfile] is the only blocking call. *)
let read_clean path =
  Lwt.return (match of_file path with m -> Some m | exception _ -> None)

(* Depth first, passing each manifest's real relative path: recursion resolves
   escaped names through their markers, so [rel] is always real-path shaped. *)
let fold_files ~start ~rel f acc =
  let rec walk dir rel acc =
    let* names = Fs_util.readdir_list dir in
    Lwt_list.fold_left_s
      (fun acc name ->
        if is_internal name then Lwt.return acc
        else (
          let path = Filename.concat dir name in
          let* is_dir = Fs_util.is_directory path in
          if is_dir then
            let* real = real_dir_name path name in
            walk path (Key.join rel real) acc
          else
            let+ m = read_clean path in
            match m with Some m -> f acc rel m | None -> acc))
      acc names
  in
  let* ok = Fs_util.is_directory start in
  if ok then walk start rel acc else Lwt.return acc

let rec clean_tmp dir =
  let* is_dir = Fs_util.is_directory dir in
  if not is_dir then Lwt.return_unit
  else
    let* names = Fs_util.readdir_list dir in
    Lwt_list.iter_s
      (fun name ->
        let path = Filename.concat dir name in
        let* is_dir = Fs_util.is_directory path in
        if is_dir then clean_tmp path
        else if Filename.check_suffix name ".tmp" then Fs_util.unlink_quiet path
        else Lwt.return_unit)
      names

(* The store, per domain: manifests keyed by logical key and nothing else. *)
module Make (C : Conf.S) = struct
  let root () = dir ~cache_root:C.cache_root C.domain_name

  (* The domain's cache chunk size applied once, so no caller carries it. *)

  let cache_chunk_size = Conf.cache_chunk_size (module C)
  let per = per ~cache_chunk_size
  let groups = groups ~cache_chunk_size
  let group_at = group_at ~cache_chunk_size

  (* For the staged path: no base means nothing to inherit. *)
  let group_at_opt base i =
    match base with None -> None | Some m -> group_at m i

  let groups_opt = function None -> [] | Some m -> groups m

  let path key =
    sidecar_path ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  let rel_of = Key.strip_prefix ~domain_prefix:C.domain_prefix

  (* Each entry is validated against the identity of the file it came from.
     Sidecars are replaced by rename, so a fresh inode (or changed size/mtime)
     invalidates it — including a write by another tsync process, which no
     in-process invalidation could catch. *)
  type memo_entry = { ino : int; size : int; mtime : float; manifest : t }

  let memo : (string, memo_entry) Hashtbl.t = Hashtbl.create 256
  let invalidate key = Hashtbl.remove memo key

  let read key =
    let p = path key in
    let* st = Fs_util.stat_opt p in
    match st with
      | None ->
          invalidate key;
          Lwt.return_none
      | Some st -> (
          let ino = st.Unix.st_ino
          and size = st.Unix.st_size
          and mtime = st.Unix.st_mtime in
          match Hashtbl.find_opt memo key with
            | Some e when e.ino = ino && e.size = size && e.mtime = mtime ->
                Lwt.return_some e.manifest
            | _ -> (
                match of_file p with
                  | manifest ->
                      Hashtbl.replace memo key { ino; size; mtime; manifest };
                      Lwt.return_some manifest
                  | exception _ -> Lwt.return_none))

  let ensure_parent key =
    let rel = rel_of key in
    let reldir = Key.parent rel in
    ensure_dirs (root ()) reldir

  let write key manifest =
    invalidate key;
    let* () = ensure_parent key in
    Fs_util.atomic_write (path key) (to_string manifest)

  let delete key =
    invalidate key;
    Fs_util.unlink_quiet (path key)

  let rename ~src_key ~dst_key =
    invalidate src_key;
    invalidate dst_key;
    let src = path src_key in
    let* exists = Lwt_unix_retry.file_exists src in
    if not exists then Lwt.return_unit
    else
      let* () = ensure_parent dst_key in
      Lwt_unix_retry.rename src (path dst_key)

  (* The mirror is the directory structure: directories exist only here. *)
  let create_dir key = ensure_dirs (root ()) (rel_of key)
  let delete_dir key = Fs_util.rm_rf (path key)

  (* After a move the escaped on-disk name hashes the new name while the marker
     inside still holds the old one. No-op for an unescaped name. *)
  let refresh_dir_marker key =
    let rel = Key.chop_slash (rel_of key) in
    let leaf = if rel = "" then "" else Filename.basename rel in
    if
      rel = ""
      || not (Name_escape.is_escaped (Name_escape.encode_component leaf))
    then Lwt.return_unit
    else (
      let dir = Filename.concat (root ()) (Name_escape.encode_key rel) in
      Fs_util.atomic_write (Filename.concat dir Name_escape.dir_marker) leaf)

  (* The staged tree is keyed like the mirror, so a staged manifest and its
     published sidecar sit at matching paths. *)

  let staged_root () =
    Cache_layout.staged_manifests_dir ~cache_root:C.cache_root C.domain_name

  let staged_path key =
    Filename.concat (staged_root ()) (Name_escape.encode_key (rel_of key))

  let staged_exists key = Lwt_unix_retry.file_exists (staged_path key)

  let read_staged key =
    let p = staged_path key in
    let* body = read_body p in
    match body with
      | None -> Lwt.return_none
      | Some body -> (
          match staged_of_string body with
            | st -> Lwt.return_some st
            | exception exn ->
                (* Unsynced user data: set aside rather than dropped, so the next
                   start does not trip over it again. *)
                Log.err "staged manifest %s unreadable (%s); moving aside" key
                  (Printexc.to_string exn);
                let* () =
                  Lwt.catch
                    (fun () -> Lwt_unix_retry.rename p (p ^ ".bad"))
                    (fun _ -> Lwt.return_unit)
                in
                Lwt.return_none)

  let write_staged key (st : staged) =
    let p = staged_path key in
    let* () = Fs_util.ensure_parent p in
    Fs_util.atomic_write p (staged_to_string st)

  let delete_staged key = Fs_util.unlink_quiet (staged_path key)

  let rename_staged ~src_key ~dst_key =
    let src = staged_path src_key in
    let* exists = Lwt_unix_retry.file_exists src in
    if not exists then Lwt.return_unit
    else (
      let dst = staged_path dst_key in
      let* () = Fs_util.ensure_parent dst in
      Lwt_unix_retry.rename src dst)

  (* Walks on-disk names: a staged manifest records its leaf name, but tree
     position is what identifies the file. *)
  let fold_staged ~rel_dir ~deep f acc =
    let start =
      if rel_dir = "" then staged_root ()
      else Filename.concat (staged_root ()) (Name_escape.encode_key rel_dir)
    in
    let rec walk dir rel acc =
      let* names = Fs_util.readdir_list dir in
      Lwt_list.fold_left_s
        (fun acc name ->
          if is_internal name || Filename.check_suffix name ".bad" then
            Lwt.return acc
          else (
            let path = Filename.concat dir name in
            let* is_dir = Fs_util.is_directory path in
            if is_dir then
              if not deep then Lwt.return acc
              else
                let* real = real_dir_name path name in
                walk path (Key.join rel real) acc
            else
              let+ body = read_body path in
              match body with
                | Some body -> (
                    match staged_of_string body with
                      | st -> f acc rel st
                      | exception _ -> acc)
                | None -> acc))
        acc names
    in
    let* ok = Fs_util.is_directory start in
    if ok then walk start rel_dir acc else Lwt.return acc

  (* Logical keys owing an upload. *)
  let list_staged () =
    fold_staged ~rel_dir:"" ~deep:true
      (fun acc rel st -> (C.domain_prefix ^ Key.join rel st.s_name) :: acc)
      []

  (* A locally created file has no published sidecar, so the mirror alone would
     not list it; for one that does, the staged size and mtime are current. *)
  let staged_entries ~rel_dir ~deep =
    fold_staged ~rel_dir ~deep
      (fun acc rel st ->
        Backend.
          {
            key = C.domain_prefix ^ Key.join rel st.s_name;
            size = Int64.to_int st.s_size;
            last_modified = st.s_mtime;
          }
        :: acc)
      []

  (* Staged entries win for the same key.
     ponytail: quadratic in (staged × published); staged files are the handful
     currently being written, so make it a table only if that stops being true. *)
  let merge_entries published staged =
    let keys =
      List.map (fun (e : Backend.file_entry) -> e.Backend.key) staged
    in
    staged
    @ List.filter
        (fun (e : Backend.file_entry) -> not (List.mem e.Backend.key keys))
        published

  (* From both trees: a locally created file has no sidecar, so its name lives
     only in the staged tree. Both escape names the same way. *)
  (* Either tree may be missing: the published one right after a full resync
     clears it, the staged one whenever nothing is being written. *)
  let readdir_opt dir =
    let* is_dir = Fs_util.is_directory dir in
    if is_dir then Fs_util.readdir_list dir else Lwt.return_nil

  let dir_of_prefix prefix =
    let rel = Key.chop_slash (rel_of prefix) in
    let p =
      if rel = "" then root ()
      else Filename.concat (root ()) (Name_escape.encode_key rel)
    in
    (rel, p)

  (* Immediate children of [prefix]: file entries plus subdirectory names. *)
  let list_children ~prefix () =
    let rel, dir = dir_of_prefix prefix in
    let* staged = staged_entries ~rel_dir:rel ~deep:false in
    let child_base =
      if rel = "" then C.domain_prefix else C.domain_prefix ^ rel ^ "/"
    in
    let* names = readdir_opt dir in
    let+ files, dirs =
      Lwt_list.fold_left_s
        (fun (files, dirs) name ->
          if is_internal name then Lwt.return (files, dirs)
          else (
            let path = Filename.concat dir name in
            let* is_dir = Fs_util.is_directory path in
            if is_dir then
              let+ real = real_dir_name path name in
              (files, real :: dirs)
            else
              let+ m = read_clean path in
              match m with
                | Some m ->
                    ( Backend.
                        {
                          key = child_base ^ m.name;
                          size = Int64.to_int m.size;
                          last_modified = m.mtime;
                        }
                      :: files,
                      dirs )
                | None -> (files, dirs)))
        ([], []) names
    in
    (merge_entries files staged, dirs)

  (* Backend keys are hashed, so only the mirror can answer this. *)
  let list_tree ~prefix () =
    let rel, start = dir_of_prefix prefix in
    let* published =
      fold_files ~start ~rel
        (fun acc rel m ->
          Backend.
            {
              key = C.domain_prefix ^ Key.join rel m.name;
              size = Int64.to_int m.size;
              last_modified = m.mtime;
            }
          :: acc)
        []
    in
    let+ staged = staged_entries ~rel_dir:rel ~deep:true in
    merge_entries published staged

  (* Published or only staged, unsorted. *)
  let walk () =
    let* published =
      fold_files ~start:(root ()) ~rel:""
        (fun acc rel m -> Key.join rel m.name :: acc)
        []
    in
    let+ staged =
      fold_staged ~rel_dir:"" ~deep:true
        (fun acc rel st -> Key.join rel st.s_name :: acc)
        []
    in
    List.sort_uniq compare (published @ staged)

  (* Staged edits take precedence over what was last published. The single
     resolution point: no caller decides this itself. *)
  let resolve key =
    let* st = read_staged key in
    match st with
      | Some st ->
          let+ published = read key in
          Some (`Staged (st, published))
      | None -> (
          let+ m = read key in
          match m with Some m -> Some (`Published m) | None -> None)

  let mirror_exists () = Fs_util.is_directory (root ())

  let init () =
    let* () = Fs_util.mkdir_p (root ()) in
    clean_tmp (root ())
end
