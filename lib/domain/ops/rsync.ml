type local =
  | Link of string
  | Hashed of string array
  | Unhashed

type side = [ `Local | `Domain ]
type source = [ `Missing | `Dir | `File of local | `Key of Manifest.t ]

type target =
  [ `Absent of side | `Dir of side | `File of local | `Key of Manifest.t ]

type skip =
  [ `Source_missing
  | `Identical
  | `Target_is_dir
  | `Target_not_a_dir
  | `Not_in_domain ]

type t =
  | Skip of skip
  | Make_dir of side
  | Rename_in_domain
  | Copy_manifest of Manifest.t
  | Upload of [ `Fresh | `Replacing ]
  | Assemble of Manifest.t
  | Patch_local of { src : Manifest.t; chunks : int list }

(* Each chunk's length is folded in beside its key, so a file cut at another
   size or ending at another byte digests differently without either being
   compared; a symlink digests its target, having no keys to fold. *)
let same_content ~src dst =
  Manifest.h1 src = Manifest.h1 dst && Manifest.h2 src = Manifest.h2 dst

let keys_match ~keys manifest =
  Array.length keys = Manifest.count manifest
  &&
  let rec same i =
    i >= Array.length keys
    || (keys.(i) = Manifest.key manifest i && same (i + 1))
  in
  same 0

(* A timestamp is not evidence about content and a manifest cannot hold one
   faithfully anyway, its mtime being a double where the filesystem counts
   nanoseconds, so identity is only ever the bytes. *)
let unchanged ~local dst =
  match (local, Manifest.symlink dst) with
    | Link a, Some b -> a = b
    | Hashed keys, None -> keys_match ~keys dst
    | Unhashed, _ -> false
    | Link _, None | Hashed _, Some _ -> false

(* No answer where index [i] does not name one span on both sides. *)
let differing ~src local =
  match local with
    | Link _ | Unhashed -> None
    | Hashed keys when Array.length keys <> Manifest.count src -> None
    | Hashed keys ->
        Some
          (List.filter
             (fun i -> keys.(i) <> Manifest.key src i)
             (List.init (Manifest.count src) Fun.id))

let decide ~move ~src target =
  match (src, target) with
    | `Missing, _ -> Skip `Source_missing
    | `Dir, (`Absent side | `Dir side) -> Make_dir side
    | `Dir, (`File _ | `Key _) -> Skip `Target_not_a_dir
    | (`File _ | `Key _), `Dir _ -> Skip `Target_is_dir
    | `Key _, `Absent `Domain when move -> Rename_in_domain
    | `Key src, `Absent `Domain -> Copy_manifest src
    | `Key src, `Key dst ->
        if same_content ~src dst then Skip `Identical else Copy_manifest src
    | `File _, `Absent `Domain -> Upload `Fresh
    | `File local, `Key dst ->
        if unchanged ~local dst then Skip `Identical else Upload `Replacing
    | `Key src, `Absent `Local -> Assemble src
    | `Key src, `File local -> (
        match differing ~src local with
          | None -> if unchanged ~local src then Skip `Identical else Assemble src
          | Some [] -> Skip `Identical
          | Some chunks -> Patch_local { src; chunks })
    | `File _, (`Absent `Local | `File _) -> Skip `Not_in_domain

let describe = function
  | Skip `Source_missing -> "gone"
  | Skip `Identical -> "same"
  | Skip `Target_is_dir -> "is-dir"
  | Skip `Target_not_a_dir -> "not-dir"
  | Skip `Not_in_domain -> "outside"
  | Make_dir _ -> "dir"
  | Rename_in_domain -> "rename"
  | Copy_manifest _ -> "publish"
  | Upload _ -> "upload"
  | Assemble _ -> "fetch"
  | Patch_local _ -> "patch"

(* A rename has already consumed the source, and a directory outlives the files
   still being moved out of it, so both keep what a move would otherwise drop. *)
let source_disposal ~move = function
  | Skip _ | Rename_in_domain | Make_dir _ -> `Keep
  | Copy_manifest _ | Upload _ | Assemble _ | Patch_local _ ->
      if move then `Drop else `Keep

(** Captured before the functor parameter of the same name shadows it. *)
type listed = Checkout.listed = {
  key : Logical_key.t;
  size : int;
  mtime : float;
}

module type FOLDER_IDS = sig
  type 'a io

  val ensure_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string io
end

module type OBJECTS = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val chunk_size : unit -> int io

    val upload :
      key:Logical_key.t ->
      src_path:string ->
      mtime:float ->
      chunk_size:int ->
      ?cancel:bool ref ->
      ?on_progress:(bytes:int -> sent:bool -> unit) ->
      unit ->
      Manifest.t io

    val upload_chunks :
      key:Logical_key.t ->
      size:int64 ->
      chunk_size:int ->
      mtime:float ->
      source:(int -> unit io Chunk_source.t io) ->
      ?cancel:bool ref ->
      unit ->
      Manifest.t io

    val fetch_manifest : key:Logical_key.t -> unit -> Manifest.t option io
  end
end

module type MANIFESTS = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit io
    val put_folder_marker : key:Logical_key.t -> unit io
    val delete_manifest : key:Logical_key.t -> unit io
  end
end

module type JOURNAL = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val write_journal_entry_body :
      ?entry_key:Journal.Entry_key.t -> Bigstring.t -> Journal.Entry_key.t io

    val bump_cursor : Journal.Entry_key.t -> unit io
    val flush_cursor : unit -> unit io
  end
end

module type MIRROR = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val published : Logical_key.t -> Manifest.t option io
    val write : Logical_key.t -> Manifest.t -> unit io
    val delete : Logical_key.t -> unit io
  end
end

module type CHECKOUT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val create_dir : Logical_key.t -> unit io

    val list_children :
      prefix:Logical_key.t -> unit -> (listed list * string list) io
  end
end

module type CONTENT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val assemble_to : Logical_key.t -> dst_path:string -> unit io

    val fetch_range :
      Logical_key.t -> dst_path:string -> offset:int -> length:int -> int io
  end
end

(** One end of the copy, named the way the command's caller named it. *)
type endpoint = Local of string | Domain of string

type outcome = Copied of int64 | Skipped of skip | Made_dir | Failed of string

type summary = {
  copied : int;
  skipped : int;
  dirs : int;
  failed : int;
  bytes_moved : int64;
}

let empty_summary =
  { copied = 0; skipped = 0; dirs = 0; failed = 0; bytes_moved = 0L }

module Over
    (Io : Io.S)
    (Fs : Fs.S with type 'a io := 'a Io.t)
    (Syscalls : Syscalls.S with type 'a io := 'a Io.t)
    (Folder_ids : FOLDER_IDS with type 'a io := 'a Io.t)
    (Objects : OBJECTS with type 'a io := 'a Io.t)
    (Manifests : MANIFESTS with type 'a io := 'a Io.t)
    (Journal_store : JOURNAL with type 'a io := 'a Io.t)
    (Mirror : MIRROR with type 'a io := 'a Io.t)
    (Checkout : CHECKOUT with type 'a io := 'a Io.t)
    (Content : CONTENT with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)
  let return = Io.return

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Lk = Logical_key.Make (C)
    module R = Objects.Make (C)
    module St = Manifests.Make (C)
    module Js = Journal_store.Make (C)
    module Mf = Mirror.Make (C)
    module Ck = Checkout.Make (C)
    module D = Content.Make (C)

    let join_rel base rel =
      if rel = "" then base else if base = "" then rel else base ^ "/" ^ rel
    let at root rel = if rel = "" then root else Filename.concat root rel

    let manifest_at prefix rel =
      let key = Lk.file (join_rel prefix rel) in
      let* m = Mf.published key in
      match m with Some _ -> return m | None -> R.fetch_manifest ~key ()

    (* A source naming one file is that file, not a folder with nothing in it:
       enumerating its children would copy nothing and report success. *)
    let one_file = [ ("", `File) ]

    let entry_ops = 2000

    (* A count alone bounds nothing a reader can feel: a run over a few hundred
       large files never reaches the cap, so every peer would see the run's
       folders and none of its files until it ended. *)
    let entry_age = 10.
    let rel_of key = Logical_key.path key

    (* Ops are published as they accumulate rather than at the end, so a run over
       a large tree stays visible to peers while it goes. *)
    let pending = ref []
    let pending_count = ref 0
    let published_at = ref 0.

    let publish () =
      match List.rev !pending with
        | [] -> return_unit
        | ops ->
            pending := [];
            pending_count := 0;
            published_at := Unix.gettimeofday ();
            let* ek =
              Js.write_journal_entry_body
                (Bigstring.of_string (Journal.encode ops))
            in
            Js.bump_cursor ek

    let add ops =
      pending := List.rev_append ops !pending;
      pending_count := !pending_count + List.length ops;
      if
        !pending_count >= entry_ops
        || Unix.gettimeofday () -. !published_at >= entry_age
      then publish ()
      else return_unit

    (* A symlink's manifest names no chunks, so there is nothing for an upload to
       inherit and the body itself is the whole copy. *)
    let copy_manifest ~src dst_key =
      match Manifest.symlink src with
        | Some _ ->
            let* () =
              St.put_manifest ~key:dst_key
                ~data:(Manifest.body ~name:(Logical_key.leaf dst_key) src)
            in
            let* () = Mf.write dst_key src in
            let+ () = add [ `Put (rel_of dst_key, Manifest.size src) ] in
            Copied 0L
        | None ->
            let* m =
              R.upload_chunks ~key:dst_key ~size:(Manifest.size src)
                ~chunk_size:(Manifest.chunk_size src) ~mtime:(Manifest.mtime src)
                ~source:(fun i ->
                  return (Chunk_source.Stored (Manifest.key src i)))
                ()
            in
            let* () = Mf.write dst_key m in
            let+ () = add [ `Put (rel_of dst_key, Manifest.size m) ] in
            Copied 0L

    let publish_symlink ~target ~mtime dst_key =
      let m =
        Manifest.make_symlink ~name:(Logical_key.leaf dst_key) ~target ~mtime
      in
      let* () =
        St.put_manifest ~key:dst_key
          ~data:(Manifest.body ~name:(Logical_key.leaf dst_key) m)
      in
      let* () = Mf.write dst_key m in
      let+ () = add [ `Put (rel_of dst_key, Manifest.size m) ] in
      Copied 0L

    let upload_local ~src_path dst_key =
      let* kind = Fs.lstat_kind src_path in
      match (kind, C.symlink_policy) with
        | `Symlink _, `Skip -> return (Skipped `Source_missing)
        | `Symlink target, `Keep ->
            let* st = Syscalls.lstat src_path in
            publish_symlink ~target ~mtime:st.Unix.st_mtime dst_key
        | _ -> (
      let* st = Fs.stat_opt_large src_path in
      match st with
        | None -> return (Failed "vanished")
        | Some st ->
            let* chunk_size = R.chunk_size () in
            let* m =
              R.upload ~key:dst_key ~src_path ~mtime:st.Unix.LargeFile.st_mtime
                ~chunk_size ()
            in
            let* () = Mf.write dst_key m in
            let+ () = add [ `Put (rel_of dst_key, Manifest.size m) ] in
            Copied (Manifest.size m))

    let assemble ~src_key dst_path =
      let* () = Fs.ensure_parent dst_path in
      let* published = Mf.published src_key in
      match Option.bind published Manifest.symlink with
        | Some target ->
            let* () = Fs.unlink_quiet dst_path in
            let+ () = Syscalls.symlink target dst_path in
            Copied 0L
        | None ->
            let size =
              Option.fold ~none:0L ~some:Manifest.size published
            in
            let+ () = D.assemble_to src_key ~dst_path in
            Copied size

    (* Consecutive indices are fetched as one range: the chunks are contiguous in
       the file, and a range is a round trip like any other. *)
    let runs_of chunks =
      List.fold_left
        (fun acc i ->
          match acc with
            | (first, last) :: rest when i = last + 1 -> (first, i) :: rest
            | _ -> (i, i) :: acc)
        [] chunks
      |> List.rev

    let patch_local ~src ~src_key dst_path chunks =
      let chunk_size = Manifest.chunk_size src in
      let size = Manifest.size src in
      let* () =
        iter_s
          (fun (first, last) ->
            let offset = Chunks.offset_of ~chunk_size first in
            let stop =
              min (Int64.to_int size)
                (Chunks.offset_of ~chunk_size last + chunk_size)
            in
            let+ (_ : int) =
              D.fetch_range src_key ~dst_path ~offset ~length:(stop - offset)
            in
            ())
          (runs_of chunks)
      in
      let+ () = Syscalls.utimes dst_path (Manifest.mtime src) (Manifest.mtime src) in
      Copied
        (Int64.of_int (List.length chunks * chunk_size))

    let make_dir side key path =
      match side with
        | `Local ->
            let+ () = Fs.mkdir_p path in
            Made_dir
        | `Domain ->
            let* () = Ck.create_dir key in
            let* () = St.put_folder_marker ~key in
            let* id =
              Folder_ids.ensure_id ~cache_root:C.cache_root
                ~domain_name:C.domain_name key
            in
            let+ () = add [ `Mkdir (rel_of key, Some id) ] in
            Made_dir

    (* Cut at the manifest's size rather than this domain's, so index [i] names
       the same span on both sides and the comparison means something. *)
    let local_keys ~chunk_size ~size path =
      let count = Chunks.count ~size ~chunk_size in
      let rec go i acc =
        if i >= count then return (Some (Array.of_list (List.rev acc)))
        else
          let len = Chunks.length_of ~size ~chunk_size i in
          let buf = Bigstring.create len in
          let* (_ : int) =
            Fs.read path buf
              ~offset:(Int64.of_int (Chunks.offset_of ~chunk_size i))
          in
          go (i + 1) (Chunks.key_of_body buf :: acc)
      in
      go 0 []

    (* Cut the way the manifest it is compared against was cut, and not read at
       all where there is no manifest to compare it to. *)
    let local_facts ~against path st =
      match against with
        | None -> return Unhashed
        | Some m ->
            let+ keys =
              local_keys
                ~chunk_size:(Manifest.chunk_size m)
                ~size:st.Unix.LargeFile.st_size path
            in
            (match keys with Some keys -> Hashed keys | None -> Unhashed)

    let rec iter_s_acc acc xs f =
      match xs with
        | [] -> return acc
        | x :: rest ->
            let* acc = f acc x in
            iter_s_acc acc rest f

    let rec walk_local ~root rel acc =
      let path = at root rel in
      let* names = Fs.readdir_list path in
      let* acc =
        iter_s_acc acc (List.sort compare names) (fun acc name ->
            let child = if rel = "" then name else rel ^ "/" ^ name in
            let* kind = Fs.lstat_kind (Filename.concat path name) in
            match kind with
              | `Dir ->
                  let acc = (child, `Dir) :: acc in
                  walk_local ~root child acc
              | `File _ | `Symlink _ -> return ((child, `File) :: acc)
              | `Missing -> return acc)
      in
      return acc

    (* Directories first and in path order, so a folder marker is published
       before anything filed under it. *)
    let entries_of = function
      | Local root -> (
          let* kind = Fs.lstat_kind root in
          match kind with
            | `File _ | `Symlink _ -> return one_file
            | `Missing -> return []
            | `Dir ->
                let+ found = walk_local ~root "" [] in
                List.stable_sort compare (List.rev found))
      | Domain prefix -> (
          let* named = manifest_at prefix "" in
          match named with
          | Some _ -> return one_file
          | None ->
          let rec walk rel acc =
            let key =
              if rel = "" then Lk.dir prefix else Lk.dir (prefix ^ "/" ^ rel)
            in
            let* files, dirs = Ck.list_children ~prefix:key () in
            let acc =
              List.fold_left
                (fun acc (l : listed) ->
                  let leaf = Logical_key.leaf l.key in
                  ((if rel = "" then leaf else rel ^ "/" ^ leaf), `File) :: acc)
                acc files
            in
            iter_s_acc acc (List.sort compare dirs) (fun acc d ->
                let child = if rel = "" then d else rel ^ "/" ^ d in
                walk child ((child, `Dir) :: acc))
          in
          let+ found = walk "" [] in
          List.stable_sort compare (List.rev found))

    let at root rel = if rel = "" then root else at root rel

    let local_side ~against path =
      let* kind = Fs.lstat_kind path in
      match kind with
        | `Missing -> return None
        | `Dir -> return None
        | `Symlink target -> return (Some (Link target))
        | `File _ -> (
            let* st = Fs.stat_opt_large path in
            match st with
              | None -> return None
              | Some st ->
                  let+ f = local_facts ~against path st in
                  Some f)

    let drop_source src rel =
      match src with
        | Local root -> Fs.unlink_quiet (at root rel)
        | Domain prefix ->
            let key = Lk.file (join_rel prefix rel) in
            let* () = St.delete_manifest ~key in
            let* () = Mf.delete key in
            add [ `Delete (rel_of key) ]

    let act ~src ~dst rel decision =
      match decision with
        | Skip s -> return (Skipped s)
        | Make_dir side ->
            let path =
              match dst with
                | Local root -> at root rel
                | Domain _ -> ""
            in
            let key =
              match dst with
                | Domain prefix -> Lk.dir (join_rel prefix rel)
                | Local _ -> Lk.root
            in
            make_dir side key path
        | Rename_in_domain ->
            let src_key =
              match src with
                | Domain prefix -> Lk.file (join_rel prefix rel)
                | Local _ -> Lk.root
            in
            let dst_key =
              match dst with
                | Domain prefix -> Lk.file (join_rel prefix rel)
                | Local _ -> Lk.root
            in
            let* m = Mf.published src_key in
            let size = Option.map Manifest.size m in
            let* () = St.put_manifest ~key:dst_key
                ~data:(Manifest.body ~name:(Logical_key.leaf dst_key)
                         (Option.get m))
            in
            let* () = Option.fold ~none:return_unit ~some:(Mf.write dst_key) m in
            let* () = St.delete_manifest ~key:src_key in
            let* () = Mf.delete src_key in
            let+ () =
              add
                [ `Rename
                    {
                      Journal.dst = rel_of dst_key;
                      src = rel_of src_key;
                      size;
                      is_dir = false;
                      id = None;
                    } ]
            in
            Copied 0L
        | Copy_manifest m ->
            let dst_key =
              match dst with
                | Domain prefix -> Lk.file (join_rel prefix rel)
                | Local _ -> Lk.root
            in
            copy_manifest ~src:m dst_key
        | Upload _ ->
            let src_path =
              match src with
                | Local root -> at root rel
                | Domain _ -> ""
            in
            let dst_key =
              match dst with
                | Domain prefix -> Lk.file (join_rel prefix rel)
                | Local _ -> Lk.root
            in
            upload_local ~src_path dst_key
        | Assemble _ ->
            let src_key =
              match src with
                | Domain prefix -> Lk.file (join_rel prefix rel)
                | Local _ -> Lk.root
            in
            let dst_path =
              match dst with
                | Local root -> at root rel
                | Domain _ -> ""
            in
            assemble ~src_key dst_path
        | Patch_local { src = m; chunks } ->
            let src_key =
              match src with
                | Domain prefix -> Lk.file (join_rel prefix rel)
                | Local _ -> Lk.root
            in
            let dst_path =
              match dst with
                | Local root -> at root rel
                | Domain _ -> ""
            in
            patch_local ~src:m ~src_key dst_path chunks

    let tally summary = function
      | Copied n ->
          {
            summary with
            copied = summary.copied + 1;
            bytes_moved = Int64.add summary.bytes_moved n;
          }
      | Skipped _ -> { summary with skipped = summary.skipped + 1 }
      | Made_dir -> { summary with dirs = summary.dirs + 1 }
      | Failed _ -> { summary with failed = summary.failed + 1 }

    let run ?(move = false) ?(dry_run = false)
        ?(on_entry = fun ~rel:_ _ -> ()) ~src ~dst () =
      pending := [];
      pending_count := 0;
      published_at := Unix.gettimeofday ();
      let* entries = entries_of src in
      let* summary =
        iter_s_acc empty_summary entries (fun summary (rel, kind) ->
            let* src_m =
              match src with
                | Domain p -> manifest_at p rel
                | Local _ -> return None
            in
            let* dst_m =
              match dst with
                | Domain p -> manifest_at p rel
                | Local _ -> return None
            in
            let* s =
              match (src, kind) with
                | _, `Dir -> return `Dir
                | Domain _, `File ->
                    return (match src_m with Some m -> `Key m | None -> `Missing)
                | Local root, `File -> (
                    let+ f =
                      local_side ~against:dst_m (at root rel)
                    in
                    match f with Some f -> `File f | None -> `Missing)
            in
            let* t =
              match dst with
                | Domain _ ->
                    return
                      (match dst_m with
                        | Some m -> `Key m
                        | None -> `Absent `Domain)
                | Local root -> (
                    let path = at root rel in
                    let* kind = Fs.lstat_kind path in
                    match kind with
                      | `Dir -> return (`Dir `Local)
                      | _ -> (
                          let+ f = local_side ~against:src_m path in
                          match f with
                            | Some f -> `File f
                            | None -> `Absent `Local))
            in
            let decision = decide ~move ~src:s t in
            on_entry ~rel decision;
            if dry_run then
              return
                (tally summary
                   (match decision with
                     | Skip s -> Skipped s
                     | Make_dir _ -> Made_dir
                     | _ -> Copied 0L))
            else
              let* outcome =
                Io.catch
                  (fun () -> act ~src ~dst rel decision)
                  (fun exn -> return (Failed (Printexc.to_string exn)))
              in
              let* () =
                match (outcome, source_disposal ~move decision) with
                  | Copied _, `Drop -> drop_source src rel
                  | _ -> return_unit
              in
              return (tally summary outcome))
      in
      let* () = publish () in
      let+ () = Js.flush_cursor () in
      summary
  end
end
