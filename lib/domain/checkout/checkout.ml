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
  Sys.file_exists (Staged_manifest.sidecar_path ~cache_root ~domain_name key)
  ||
    match of_file (sidecar_path ~cache_root ~domain_name key) with
    | m ->
        List.for_all
          (fun g ->
            Sys.file_exists
              (Cache_layout.chunk_path ~cache_root ~domain_name
                 (Manifest.Group.key g)))
          (Manifest.Group.all ~table:m
             ~per:
               (Conf.chunks_per_group ~chunk_size:(chunk_size m)
                  ~cache_chunk_size))
    | exception _ -> false

(* Mapped, not read: a listing wants name, size and mtime, and never touches the
   chunk keys. *)
(* What this needs below it. *)
module type FS = sig
  type 'a io

  val mkdir_p : string -> unit io
  val is_directory : string -> bool io
  val readdir_list : string -> string list io
  val atomic_write : string -> string -> unit io
  val rm_rf : string -> unit io
  val unlink_quiet : string -> unit io
  val real_dir_name : string -> string -> string io
end

module type SYSCALLS = sig
  type 'a io

  val file_exists : string -> bool io
  val rename : string -> string -> unit io
end

module type MIRROR = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val root : unit -> string
    val path : Logical_key.t -> string
    val ensure_parent : Logical_key.t -> unit io
    val write : Logical_key.t -> Manifest.t -> unit io
    val forget : Logical_key.t -> unit
  end

  val ensure_dirs : string -> string -> unit io
end

module type STAGED = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val fold :
      rel_dir:string ->
      deep:bool ->
      ('a -> Logical_key.t -> Staged_manifest.staged -> 'a) ->
      'a ->
      'a io

    val entries :
      rel_dir:string ->
      deep:bool ->
      (Logical_key.t * Staged_manifest.staged) list io
  end
end

module type FOLDERS = sig
  type 'a io

  val reparent :
    cache_root:string -> domain_name:string -> Logical_key.t -> unit io
end

module Over
    (Io : Io.S)
    (Fs : FS with type 'a io := 'a Io.t)
    (Retry : SYSCALLS with type 'a io := 'a Io.t)
    (Mf : MIRROR with type 'a io := 'a Io.t)
    (Sm : STAGED with type 'a io := 'a Io.t)
    (Folders : FOLDERS with type 'a io := 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x
  let return_unit = Io.return ()
  let return_some x = Io.return (Some x)
  let return_true = Io.return true
  let return_false = Io.return false

  let rec iter_s f = function
    | [] -> return_unit
    | x :: rest -> Io.bind (f x) (fun () -> iter_s f rest)

  (* Bound before [Make] shadows [Mf] with its per-domain result. *)
  let ensure_dirs = Mf.ensure_dirs

  let rec fold_left_s f acc = function
    | [] -> Io.return acc
    | x :: rest -> Io.bind (f acc x) (fun acc -> fold_left_s f acc rest)

  let read_clean path =
    Io.return (match of_file path with m -> Some m | exception _ -> None)

  (* Escaped names are resolved through their markers, so the [rel] a walk hands
     out is always real-path shaped. *)
  let real_file_name name m =
    if Stored_key.is_escaped name then recorded_name m else name

  let rec clean_tmp dir =
    let* is_dir = Fs.is_directory dir in
    if not is_dir then return_unit
    else
      let* names = Fs.readdir_list dir in
      iter_s
        (fun name ->
          let path = Filename.concat dir name in
          let* is_dir = Fs.is_directory path in
          if is_dir then clean_tmp path
          else if Filename.is_temp_name name then Fs.unlink_quiet path
          else return_unit)
        names

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

    (* Backend keys are hashed, so only the mirror can answer this. *)
    (* Inside the functor because it hands back the key each file is filed under,
       which needs the domain the walk belongs to. *)
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

    let reap_leftovers () =
      let* () = ensure_root () in
      clean_tmp (Mf.root ())
  end
end
