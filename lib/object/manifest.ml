(* A published file's metadata: size, mtime and the ordered keys of the chunks
   holding its bytes.

   Header fields are lifted into this record; the chunks stay in the
   {!Chunk_table} mapping, so a 32 GB file's 31,230 keys are never materialized
   to answer "what is this file called?". *)

(* A name belongs to where a manifest is filed, so it is not a field here. The
   body carries one only for the locations that cannot express it: a backend key
   is [<folder-id>/<hash>] and an escaped cache leaf is [.tsync-esc-<hash>],
   both one-way. *)
type t = {
  size : int64;
  chunk_size : int;
  chunks : Chunk_table.t;
  h1 : string;
  h2 : string;
  mtime : float;
  symlink : string option;
}

(* Only the location can say whether this is worth consulting, so a caller
   holding a key uses the key instead. *)
let recorded_name m = Chunk_table.name m.chunks

(* What an upload produces per chunk. Read paths go through the table. *)
type chunk_entry = { index : int; h1 : string; h2 : string; size : int }

let chunk_key (entry : chunk_entry) = entry.h1 ^ "-" ^ entry.h2

(* Content addressing means a chunk's key is a function of its bytes, so a body
   can always be held against the name it arrived under. Composed where the
   stores can reach it without depending on the shapes that reference a chunk:
   the check runs inside a backend driver. *)
let key_of_body = Chunk_layout.key_of_body

(* The reverse, for a chunk kept from a previous upload: the two digests are the
   key's halves. *)
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

(* Derived from the file's {i own} chunk size, so a file uploaded under a
   different setting still groups correctly. *)

let per ~cache_chunk_size (m : t) =
  Chunk_group.per_group ~chunk_size:m.chunk_size ~cache_chunk_size

let groups ~cache_chunk_size m =
  Chunk_group.all ~table:m.chunks ~per:(per ~cache_chunk_size m)

let group_at ~cache_chunk_size m i =
  Chunk_group.of_table ~table:m.chunks ~per:(per ~cache_chunk_size m) i

(* Hashed over the ordered chunk digests, so a changed file's manifest rebuilds
   from its chunk entries without re-reading untouched bytes.

   What one chunk contributes is spelled once below: an upload that addresses
   its keys and a caller holding them as a list must reach the same digest for
   the same file, and two spellings of this line is how that stops being true. *)
let chunk_digest ~key ~size = Printf.sprintf "%s-%d;" key size

let digest_fold feed =
  let s1 = Xxhash.create 0 and s2 = Xxhash.create 1 in
  feed (fun d ->
      Xxhash.update s1 d;
      Xxhash.update s2 d);
  (Xxhash.digest_hex s1, Xxhash.digest_hex s2)

let digest_of_chunks chunks =
  digest_fold (fun add ->
      List.iter
        (fun (c : chunk_entry) ->
          add (chunk_digest ~key:(chunk_key c) ~size:c.size))
        chunks)

let digest_of_keys ~count ~key ~len =
  digest_fold (fun add ->
      for i = 0 to count - 1 do
        add (chunk_digest ~key:(key i) ~size:(len i))
      done)

let of_table chunks =
  {
    size = Chunk_table.size chunks;
    chunk_size = Chunk_table.chunk_size chunks;
    chunks;
    h1 = Chunk_table.h1 chunks;
    h2 = Chunk_table.h2 chunks;
    mtime = Chunk_table.mtime chunks;
    symlink = Chunk_table.symlink chunks;
  }

let of_string s = of_table (Chunk_table.of_string s)
let of_chunk c = of_table (Chunk_table.of_chunk c)

(* Mapped: chunk keys cost no heap and the pages are reclaimable. *)
let of_file path = of_table (Chunk_table.of_file path)

(* Encoding needs a name, so every caller states one; a version snapshot and a
   trashed marker are the only ones passing anything but the key's own leaf. *)
let to_string ~name (m : t) =
  Chunk_table.encode ~name ~size:m.size ~chunk_size:m.chunk_size ~mtime:m.mtime
    ~h1:m.h1 ~h2:m.h2 ~symlink:m.symlink
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

(* [s_size] is authoritative rather than derived from a file length, so a
   truncate either way is a metadata write plus at most one boundary fixup.

   A staged manifest on disk means an upload is owed; once [s_published] is set
   it is instead the commit record of a promotion to replay. *)

(** Where a chunk's bytes are within [staged/chunks/<uuid>]. One body holds
    every staged member of a cache group, so the offset is what separates them
    and is carried rather than derived: it is fixed when the bytes are written,
    while the group size it would be derived from is configuration and can
    change between runs. *)
type body = { uuid : string; offset : int }

type slot =
  | Staged of body
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
  (* The offset is omitted when zero, which is every slot of an ungrouped file
     and every first member of a group. *)
  | Staged { uuid; offset } ->
      `Assoc
        (("u", `String uuid)
        :: (if offset = 0 then [] else [("o", `Int offset)]))
  | Inherit -> `Assoc []
  | Zero -> `Assoc [("z", `Bool true)]

let slot_of_json j =
  let open Yojson.Basic.Util in
  match j |> member "u" with
    | `String uuid ->
        let offset = match j |> member "o" with `Int o -> o | _ -> 0 in
        Staged { uuid; offset }
    | _ -> ( match j |> member "z" with `Bool true -> Zero | _ -> Inherit)

let slot_body = function Staged b -> Some b | Inherit | Zero -> None

(* Deduplicated, since a group's members share one. *)
let body_uuids slots =
  Array.fold_left
    (fun acc slot ->
      match slot_body slot with
        | Some { uuid; _ } when not (List.mem uuid acc) -> uuid :: acc
        | _ -> acc)
    [] slots
  |> List.sort compare

(* Read as well as written, so a sidecar from a newer build is set aside rather
   than decoded into something it does not mean. *)
let staged_version = 2

let staged_of_version json =
  let open Yojson.Basic.Util in
  match json |> member "v" with
    | `Int v when v > staged_version ->
        failwith (Printf.sprintf "staged manifest version %d" v)
    | _ -> ()

let staged_to_string (st : staged) =
  Yojson.Basic.to_string
    (`Assoc
       ([
          ("v", `Int staged_version);
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
             [
               ( "published",
                 (* Same file, so the same name: this is the published body of
                    the very record carrying it. *)
                 `String (Base64.encode_string (to_string ~name:st.s_name m)) );
             ]))

let staged_of_string body =
  let open Yojson.Basic.Util in
  let json = Yojson.Basic.from_string body in
  staged_of_version json;
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

(* The tree mirrors real paths: directories are real directories, and a name the
   filesystem cannot hold verbatim becomes an escaped handle plus a marker file
   carrying the real one. *)

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

(* Synchronous, for the CLI listing (plain non-Lwt code).

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

let real_dir_name dir_path name =
  if Name_escape.is_escaped name then
    read_marker (Filename.concat dir_path Name_escape.dir_marker)
  else Lwt.return name

(* A name marker goes inside each escaped component. *)
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
  Fs_util.is_temp_name name
  || name = Name_escape.dir_marker
  || name = Folder_ids.marker_name

let read_body path =
  Lwt.catch
    (fun () ->
      let+ s = Lwt_unix_retry.with_file ~mode:Lwt_io.Input path Lwt_io.read in
      Some s)
    (fun _ -> Lwt.return_none)

(* Mapped, not read: a listing wants name, size and mtime, and never touches the
   chunk keys. *)
let read_clean path =
  Lwt.return (match of_file path with m -> Some m | exception _ -> None)

(* Escaped names are resolved through their markers, so the [rel] a walk hands
   out is always real-path shaped. *)
let real_file_name name m =
  if Name_escape.is_escaped name then recorded_name m else name

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
            match m with
              | Some m -> f acc rel (real_file_name name m) m
              | None -> acc))
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
        else if Fs_util.is_temp_name name then Fs_util.unlink_quiet path
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

  let path key =
    sidecar_path ~cache_root:C.cache_root ~domain_name:C.domain_name
      ~domain_prefix:C.domain_prefix key

  let rel_of = Key.strip_prefix ~domain_prefix:C.domain_prefix

  (* Sidecars are replaced by rename, so a fresh inode (or changed size/mtime)
     invalidates the entry — including a write by another tsync process, which
     no in-process invalidation could catch. *)
  type memo_entry = { ino : int; size : int; mtime : float; manifest : t }

  (* A memoised manifest holds the mapping it was read through, so the table
     bounds live mappings rather than merely bytes: an import reads one sidecar
     per file, and unbounded that is one mapping per file held for the life of
     the process — 19,261 of them, 75 MB of pinned page cache, in the run that
     found this.

     Eviction is by insertion rather than by use, which costs nothing worth
     measuring here: the walks that fill it touch each key once, and a dropped
     entry is a re-read of a page the kernel still has. *)
  let memo_capacity = 1024
  let memo : (string, memo_entry) Hashtbl.t = Hashtbl.create 256
  let memo_order : string Queue.t = Queue.create ()
  let invalidate key = Hashtbl.remove memo key

  let memoize key entry =
    Hashtbl.replace memo key entry;
    Queue.add key memo_order;
    while Queue.length memo_order > memo_capacity do
      Hashtbl.remove memo (Queue.pop memo_order)
    done

  let memo_size () = Hashtbl.length memo

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
                      memoize key { ino; size; mtime; manifest };
                      Lwt.return_some manifest
                  | exception _ -> Lwt.return_none))

  let ensure_parent key =
    let rel = rel_of key in
    let reldir = Key.parent rel in
    ensure_dirs (root ()) reldir

  (* Sole writer of a manifest body in the cache, and it stamps the name from
     the key, so a mirror manifest always records the name it is filed under. *)
  let write key manifest =
    invalidate key;
    let* () = ensure_parent key in
    Fs_util.atomic_write (path key)
      (to_string ~name:(Key.leaf ~domain_prefix:C.domain_prefix key) manifest)

  let delete key =
    invalidate key;
    Fs_util.unlink_quiet (path key)

  (* A directory keeps its real name in a marker beside it, for the same reason
     a manifest keeps one in its body: an escaped on-disk name is a hash. *)
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

  (* Moving is half of a rename: whatever records the name — a manifest's body
     for a file, the marker beside it for a directory — has to be brought to the
     destination's, and both are done here so no caller need know which it
     moved. *)
  let rename ~src_key ~dst_key =
    invalidate src_key;
    invalidate dst_key;
    let src = path src_key in
    let* exists = Lwt_unix_retry.file_exists src in
    if not exists then Lwt.return_unit
    else (
      let dst = path dst_key in
      let* () = ensure_parent dst_key in
      let* () = Lwt_unix_retry.rename src dst in
      let* is_dir = Fs_util.is_directory dst in
      if is_dir then refresh_dir_marker dst_key
      else (
        match of_file dst with
          | m -> write dst_key m
          | exception _ -> Lwt.return_unit))

  (* The mirror is the directory structure: directories exist only here. *)
  let create_dir key = ensure_dirs (root ()) (rel_of key)
  let delete_dir key = Fs_util.rm_rf (path key)

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

  (* Stamped from the key, as {!write} is: this name is what a listing shows
     before an upload lands. *)
  let write_staged key (st : staged) =
    let p = staged_path key in
    let* () = Fs_util.ensure_parent p in
    Fs_util.atomic_write p
      (staged_to_string
         { st with s_name = Key.leaf ~domain_prefix:C.domain_prefix key })

  let delete_staged key = Fs_util.unlink_quiet (staged_path key)

  let rename_staged ~src_key ~dst_key =
    let src = staged_path src_key in
    let* exists = Lwt_unix_retry.file_exists src in
    if not exists then Lwt.return_unit
    else (
      let dst = staged_path dst_key in
      let* () = Fs_util.ensure_parent dst in
      let* () = Lwt_unix_retry.rename src dst in
      let* body = read_body dst in
      match body with
        | None -> Lwt.return_unit
        | Some body -> (
            match staged_of_string body with
              | st -> write_staged dst_key st
              | exception _ -> Lwt.return_unit))

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
                      | st ->
                          let leaf =
                            if Name_escape.is_escaped name then st.s_name
                            else name
                          in
                          f acc rel leaf st
                      | exception _ -> acc)
                | None -> acc))
        acc names
    in
    let* ok = Fs_util.is_directory start in
    if ok then walk start rel_dir acc else Lwt.return acc

  (* Logical keys owing an upload. *)
  let list_staged () =
    fold_staged ~rel_dir:"" ~deep:true
      (fun acc rel leaf (_ : staged) ->
        (C.domain_prefix ^ Key.join rel leaf) :: acc)
      []

  (* Every staged body reachable from a manifest: what a sweep of the body trees
     must keep. *)
  let staged_uuids () =
    fold_staged ~rel_dir:"" ~deep:true
      (fun acc _ _ st ->
        let acc =
          match st.s_whole with Some uuid -> uuid :: acc | None -> acc
        in
        List.rev_append (body_uuids st.s_slots) acc)
      []

  (* Cutoff 0 deletes no file, only prunes what is left empty. *)
  let prune_staged_dirs () =
    let+ (_ : bool) = Fs_util.reap_older_than ~cutoff:0. (staged_root ()) in
    ()

  (* A locally created file has no published sidecar, so the mirror alone would
     not list it; for one that does, the staged size and mtime are current. *)
  let staged_entries ~rel_dir ~deep =
    fold_staged ~rel_dir ~deep
      (fun acc rel leaf st ->
        Backend.
          {
            key = C.domain_prefix ^ Key.join rel leaf;
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
                          key = child_base ^ real_file_name name m;
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
        (fun acc rel leaf m ->
          Backend.
            {
              key = C.domain_prefix ^ Key.join rel leaf;
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
        (fun acc rel leaf (_ : t) -> Key.join rel leaf :: acc)
        []
    in
    let+ staged =
      fold_staged ~rel_dir:"" ~deep:true
        (fun acc rel leaf (_ : staged) -> Key.join rel leaf :: acc)
        []
    in
    List.sort_uniq compare (published @ staged)

  (* The single resolution point: no caller decides this itself. *)
  let resolve key =
    let* st = read_staged key in
    match st with
      | Some st ->
          let+ published = read key in
          Some (`Staged (st, published))
      | None -> (
          let+ m = read key in
          match m with Some m -> Some (`Published m) | None -> None)

  let ensure_root () = Fs_util.mkdir_p (root ())

  let reap_leftovers () =
    let* () = ensure_root () in
    clean_tmp (root ())
end
