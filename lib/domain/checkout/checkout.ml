open Manifest

(* The tree mirrors real paths: directories are real directories, and a name the
   filesystem cannot hold verbatim becomes an escaped handle plus a marker file
   carrying the real one. *)

type listed = { key : Logical_key.t; size : int; mtime : float }

let dir ~cache_root domain_name =
  Cache_layout.manifests_dir ~cache_root domain_name

let sidecar_path = Cache_layout.manifest_path

(* Synchronous, for the CLI listing, which has no loop to run in.

   ponytail: a bool, so a partly cached file reads as remote. Return the chunk
   counts here if `tsync ls` should distinguish "partial n/m". *)
let is_local
    ({ Conf.cache_root; domain_name; cache_chunk_size } : Conf.locality) key =
  (* A cache chunk is whole when nothing stands beside it: a body a read filled
     part of is on disk under the same name, and taking its presence for the
     whole file would report a file as local that still has to be fetched. *)
  let held key =
    Sys.file_exists (Cache_layout.chunk_path ~cache_root ~domain_name key)
    && not
         (Sys.file_exists
            (Cache_layout.chunk_manifest_path ~cache_root ~domain_name key))
  in
  Sys.file_exists (Staged_manifest.sidecar_path ~cache_root ~domain_name key)
  ||
  (* Mapped, not read: a listing wants name, size and mtime, and never
       touches the chunk keys. *)
  match of_file (sidecar_path ~cache_root ~domain_name key) with
    | m ->
        List.for_all
          (fun g -> held (Manifest.Group.key g))
          (Manifest.Group.all ~table:m
             ~per:
               (Conf.chunks_per_group ~chunk_size:(chunk_size m)
                  ~cache_chunk_size))
    | exception _ -> false

module type S = sig
  type 'a io

  val rename : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io
  val create_dir : Logical_key.t -> unit io
  val delete_dir : Logical_key.t -> unit io

  val list_children :
    prefix:Logical_key.t -> unit -> (listed list * string list) io

  val list_tree : prefix:Logical_key.t -> unit -> listed list io
  val walk : unit -> string list io
  val ensure_root : unit -> unit io

  val record :
    parent:Logical_key.t ->
    Inode_tree.entry ->
    (Logical_key.t * [ `Same | `Changed | `Replaced of string ]) io

  val sweep_stale : cutoff:float -> unit -> Journal.op list io
end

module type OVER = sig
  type 'a io

  module Make (C : Conf.S with type 'a io = 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (Fs : Cache_layout.FS with type 'a io := 'a Io.t)
    (Retry : Syscalls.S with type 'a io := 'a Io.t)
    (Mf : Manifests.OVER with type 'a io := 'a Io.t)
    (Sm : Staged_manifest.OVER with type 'a io := 'a Io.t)
    (Folders : Folder_ids.S with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  (* Bound before [Make] shadows [Mf] with its per-domain result. *)
  let ensure_dirs = Mf.ensure_dirs

  let read_clean path =
    Io.return (match of_file path with m -> Some m | exception _ -> None)

  (* Escaped names are resolved through their markers, so the [rel] a walk hands
     out is always real-path shaped. *)
  let real_file_name name m =
    if Stored_key.is_escaped name then recorded_name m else name

  (* The store, per domain: manifests keyed by logical key and nothing else. *)
  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Lk = Logical_key.Make (C)
    module Sm = Sm.Make (C)
    module Mf = Mf.Make (C)

    let rel_of = Logical_key.path

    (* A directory keeps its real name in a marker beside it, for the same reason
       a manifest keeps one in its body: an escaped on-disk name is a hash. *)
    let refresh_dir_marker key =
      let leaf = Logical_key.leaf key in
      if leaf = "" || not (Stored_key.is_escaped (Stored_key.escape leaf)) then
        return_unit
      else
        Fs.atomic_write
          (Filename.concat (Mf.path key) Stored_key.dir_name_leaf)
          leaf

    (* Moving is half of a rename: whatever records the name — a manifest's body
       for a file, and for a directory both the marker beside it and the folder's
       own — has to be brought to the destination's, and all of it is done here so
       no caller need know which it moved, nor remember that a folder unreparented
       is a folder unreachable by id. *)
    let rename ~src_key ~dst_key =
      Mf.forget src_key;
      Mf.forget dst_key;
      let src = Mf.path src_key in
      let* exists = Retry.file_exists src in
      if not exists then return_unit
      else (
        let dst = Mf.path dst_key in
        let* () = Mf.ensure_parent dst_key in
        let* () = Retry.rename src dst in
        let* is_dir = Fs.is_directory dst in
        if is_dir then
          let* () = refresh_dir_marker dst_key in
          Folders.reparent ~cache_root:C.cache_root ~domain_name:C.domain_name
            dst_key
        else (
          match of_file dst with
            | m -> Mf.write dst_key m
            | exception _ -> return_unit))

    (* The mirror is the directory structure: directories exist only here. *)
    let create_dir key = ensure_dirs (Mf.root ()) (rel_of key)
    let delete_dir key = Fs.rm_rf (Mf.path key)

    (* Staged entries win for the same key.
       ponytail: quadratic in (staged × published); staged files are the handful
       currently being written, so make it a table only if that stops being true. *)
    let staged_listed ~rel_dir ~deep =
      let+ staged = Sm.entries ~rel_dir ~deep in
      List.map
        (fun (key, (st : Staged_manifest.staged)) ->
          {
            key;
            size = Int64.to_int st.Staged_manifest.s_size;
            mtime = st.Staged_manifest.s_mtime;
          })
        staged

    (* Staged wins: what is owed is what a reader will get next. *)
    let merge_entries published staged =
      staged
      @ List.filter
          (fun p ->
            not (List.exists (fun s -> Logical_key.equal s.key p.key) staged))
          published

    (* Either tree may be missing: the published one right after a full resync
       clears it, the staged one whenever nothing is being written. *)
    let readdir_opt dir =
      let* is_dir = Fs.is_directory dir in
      if is_dir then Fs.readdir_list dir else Io.return []

    let dir_of_prefix prefix = (rel_of prefix, Mf.path prefix)

    let list_children ~prefix () =
      let rel, dir = dir_of_prefix prefix in
      let* staged = staged_listed ~rel_dir:rel ~deep:false in
      let child_dir = Lk.dir rel in
      let* names = readdir_opt dir in
      let+ files, dirs =
        fold_left_s
          (fun (files, dirs) name ->
            if Stored_key.internal_leaf name then Io.return (files, dirs)
            else (
              let path = Filename.concat dir name in
              let* is_dir = Fs.is_directory path in
              if is_dir then
                let+ real = Fs.real_dir_name path name in
                (files, real :: dirs)
              else
                let+ m = read_clean path in
                match m with
                  | Some m ->
                      ( {
                          key =
                            Logical_key.file_in child_dir
                              (real_file_name name m);
                          size = Int64.to_int (size m);
                          mtime = mtime m;
                        }
                        :: files,
                        dirs )
                  | None -> (files, dirs)))
          ([], []) names
      in
      (merge_entries files staged, dirs)

    (* Backend keys are hashed, so only the mirror can answer this. Inside the
       functor because it hands back the key each file is filed under, which
       needs the domain the walk belongs to. *)
    let fold_files ~start ~key f acc =
      let rec walk dir key acc =
        let* names = Fs.readdir_list dir in
        fold_left_s
          (fun acc name ->
            if Stored_key.internal_leaf name then Io.return acc
            else (
              let path = Filename.concat dir name in
              let* is_dir = Fs.is_directory path in
              if is_dir then
                let* real = Fs.real_dir_name path name in
                walk path (Logical_key.dir_in key real) acc
              else
                let+ m = read_clean path in
                match m with
                  | Some m ->
                      f acc (Logical_key.file_in key (real_file_name name m)) m
                  | None -> acc))
          acc names
      in
      let* ok = Fs.is_directory start in
      if ok then walk start key acc else Io.return acc

    let list_tree ~prefix () =
      let rel, start = dir_of_prefix prefix in
      let* published =
        fold_files ~start ~key:(Lk.dir rel)
          (fun acc key m ->
            { key; size = Int64.to_int (size m); mtime = mtime m } :: acc)
          []
      in
      let+ staged = staged_listed ~rel_dir:rel ~deep:true in
      merge_entries published staged

    (* Published or only staged, unsorted. *)
    let walk () =
      let* published =
        fold_files ~start:(Mf.root ()) ~key:Lk.root
          (fun acc key (_ : t) -> Logical_key.path key :: acc)
          []
      in
      let+ staged =
        Sm.fold ~rel_dir:"" ~deep:true
          (fun acc key (_ : Staged_manifest.staged) ->
            Logical_key.path key :: acc)
          []
      in
      List.sort_uniq compare (published @ staged)

    let ensure_root () = Fs.mkdir_p (Mf.root ())

    (* Where a folder's child is filed and under what name, shared so a resync
       and a browse leave the same tree behind. The name is in the body: the key
       a child was read by is hashed. What was there before is read first, so a
       resync can tell what it changed without a second copy of the tree. *)
    let record ~parent (entry : Inode_tree.entry) =
      match entry.Inode_tree.body with
        | Inode_tree.Dir marker ->
            let key = Logical_key.dir_in parent marker.Folder.name in
            let* held =
              Folders.lookup_id ~cache_root:C.cache_root
                ~domain_name:C.domain_name key
            in
            let+ () =
              Folders.write ~cache_root:C.cache_root ~domain_name:C.domain_name
                key marker
            in
            let state =
              match held with
                | None -> `Changed
                | Some id when id = marker.Folder.id -> `Same
                | Some id -> `Replaced id
            in
            (key, state)
        | Inode_tree.File manifest ->
            let key =
              Logical_key.file_in parent (Manifest.recorded_name manifest)
            in
            let* held = Mf.published key in
            let+ () = Mf.write key manifest in
            (* The fields a reader is told about: a manifest that differs in
               none of them is the same item to it. *)
            let same =
              match held with
                | Some m ->
                    h1 m = h1 manifest
                    && size m = size manifest
                    && mtime m = mtime manifest
                    && symlink m = symlink manifest
                | None -> false
            in
            (key, if same then `Same else `Changed)

    (* An entry the walk rewrote carries its mtime; one it did not is one the
       store no longer has. Every live marker is rewritten on each visit, so a
       folder whose own marker is stale was not visited and nothing under it
       was: it goes whole. A folder whose id the index now places elsewhere
       moved, and the walk reported it there under that id. *)
    let sweep_stale ~cutoff () =
      (* An mtime comes from a coarser clock than the cutoff: a write in the
         first tick of the walk can predate it by a few milliseconds. *)
      let cutoff = cutoff -. 1. in
      let stale path =
        let+ st = Fs.stat_opt path in
        match st with Some st -> st.Unix.st_mtime < cutoff | None -> false
      in
      let quiet f = Io.catch f (fun _ -> return_unit) in
      let stale_folder path key ops =
        let marker_path = Filename.concat path Folders.marker_name in
        let* marker = Fs.read_file_opt marker_path in
        match Option.bind marker Folder.marker_of_string with
          | None -> Io.return None
          | Some m ->
              let* is_stale = stale marker_path in
              if not is_stale then Io.return None
              else
                let* elsewhere =
                  Folders.key_of_id ~cache_root:C.cache_root
                    ~domain_name:C.domain_name ~root:Lk.root m.Folder.id
                in
                let+ () = Fs.rm_rf path in
                (* A folder found elsewhere is reported as the move from here
                   to there, whether the walk brought that copy in or it was
                   already held: a reader that filed the folder here learns
                   where it went either way. *)
                let op =
                  match elsewhere with
                    | Some k when not (Logical_key.equal k key) ->
                        `Rename
                          {
                            Journal.dst = rel_of k;
                            src = rel_of key;
                            size = None;
                            is_dir = true;
                            id = Some m.Folder.id;
                          }
                    | _ -> `Rmdir (rel_of key, Some m.Folder.id)
                in
                Some (op :: ops)
      in
      (* Answers the ops so far and how many entries the directory still holds:
         one left empty is removed, as before the walk had anything to say. *)
      let rec walk dir key ops =
        let* names = Fs.readdir_list_quiet dir in
        fold_left_s
          (fun (ops, left) name ->
            let path = Filename.concat dir name in
            let* is_dir = Fs.is_directory path in
            if is_dir then
              let* real = Fs.real_dir_name path name in
              let child = Logical_key.dir_in key real in
              let* dropped = stale_folder path child ops in
              match dropped with
                | Some ops -> Io.return (ops, left)
                | None ->
                    let* ops, held = walk path child ops in
                    if held = 0 then
                      let+ () = quiet (fun () -> Retry.rmdir path) in
                      (ops, left)
                    else Io.return (ops, left + 1)
            else
              let* is_stale = stale path in
              if not is_stale then Io.return (ops, left + 1)
              else
                let* m =
                  if Stored_key.internal_leaf name then Io.return None
                  else read_clean path
                in
                let+ () = quiet (fun () -> Retry.unlink path) in
                match m with
                  | Some m ->
                      let file =
                        Logical_key.file_in key (real_file_name name m)
                      in
                      (`Delete (rel_of file) :: ops, left)
                  | None -> (ops, left))
          (ops, 0) names
      in
      let+ ops, _ = walk (Mf.root ()) Lk.root [] in
      List.rev ops
  end
end
