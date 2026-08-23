(* The local cache-chunk store: {!Manifest.Group} bodies named by a content key
   derived from the stored chunks they hold.

   A group is present iff its file exists and may be deleted at any moment, so
   callers must treat a miss as ordinary (see {!read_into}). *)

open Lwt.Syntax

(* Narrower than [Remote.S] so the store has no cycle with it and can be driven
   by a stub in tests. *)
module type Fetch = sig
  val get_chunk : chunk_key:string -> Bigstring.t Lwt.t
end

(* What a read cost. Hoisted out of [Make]: it describes a read, not one
   store's state, and the staged half names it too. *)
type served = { bytes : int; from_backend : bool }

module Make (C : Conf.S) (F : Fetch) = struct
  let path group =
    Cache_layout.chunk_path ~cache_root:C.cache_root ~domain_name:C.domain_name
      (Manifest.Group.key group)

  let exists group = Lwt_unix_retry.file_exists (path group)

  (* Keyed by content, so two readers of one group share a fetch whether or not
     they are reading the same file.

     Owner and joiners share one record, so a reader that only waited on someone
     else's fetch is told the group came from a backend too -- which is what it
     was held up by. *)
  type inflight = { mutable done_ : unit Lwt.t; mutable from_backend : bool }

  let fetching : (string, inflight) Hashtbl.t = Hashtbl.create 64
  let in_flight () = Hashtbl.length fetching

  (* The file is sized up front and each member written at its own offset, so
     members are produced concurrently and land in any order: a cold group costs
     about one round trip whatever [cache_chunk_size] is.

     {!Fs_util.atomic_write_at} requires every byte covered exactly once, which
     the length check enforces: a member disagreeing with the manifest fails the
     write rather than reaching a caller as file content. *)
  let write_group group body =
    let p = path group in
    let* () = Fs_util.ensure_parent p in
    (* Atomic, so presence alone proves a complete body. *)
    Fs_util.atomic_write_at p ~size:(Manifest.Group.bytes group) (fun put ->
        Lwt_list.iter_p
          (fun i ->
            let* data = body i in
            let expected = Manifest.Group.size group i in
            if Bigstring.length data <> expected then
              Lwt.fail
                (Backend.Backend_error
                   (Printf.sprintf "chunk %s: have %d bytes, manifest says %d"
                      (Manifest.Group.member_key group i)
                      (Bigstring.length data) expected))
            else put ~offset:(Manifest.Group.offset group i) data)
          (Manifest.Group.indices group))

  (* Bounds fetches that have started, not groups asked for: a fetch opens its
     destination before waiting for a download slot, so without this every
     pending group holds a descriptor while only [max_downloads] make progress —
     247 open files inside 200ms on a 250 MB file at a 1 MiB group size, against
     a 256 descriptor limit.

     Bounded here rather than at the callers so every route in gets it. *)
  let slots = Lwt_bounded.create ~max:C.max_downloads ()

  let fetch group =
    Lwt_bounded.use slots (fun () ->
        write_group group (fun i ->
            F.get_chunk ~chunk_key:(Manifest.Group.member_key group i)))

  (* Concurrent callers await the same fetch; [force] re-fetches a body believed
     corrupt. Answers whether the body had to come from a backend. *)
  let ensure_fetched ?(force = false) ~group () =
    let key = Manifest.Group.key group in
    match Hashtbl.find_opt fetching key with
      | Some entry ->
          let+ () = entry.done_ in
          entry.from_backend
      | None ->
          let entry = { done_ = Lwt.return_unit; from_backend = false } in
          let t =
            Lwt.finalize
              (fun () ->
                (* Load-bearing: the table entry must be visible to a second
                   caller before this one touches the filesystem, and every step
                   below yields. *)
                let* () = Lwt.pause () in
                let* present =
                  if force then Lwt.return_false else exists group
                in
                if present then Lwt.return_unit
                else (
                  (* Before [fetch], not inside it: the wait on [slots] is part
                     of what the network costs this reader. *)
                  entry.from_backend <- true;
                  fetch group))
              (fun () ->
                Hashtbl.remove fetching key;
                Lwt.return_unit)
          in
          (* Filled in after the fact rather than at construction: [Lwt.finalize]
             above runs as far as that [Lwt.pause ()] and no further, so no
             second caller can reach the table in between. *)
          entry.done_ <- t;
          Hashtbl.replace fetching key entry;
          let+ () = t in
          entry.from_backend

  let ensure ?force ~group () =
    let+ _ = ensure_fetched ?force ~group () in
    ()

  (* The tail of a promotion, where every member is a local staged body.
     Idempotent: a body already under this key is the same bytes. *)
  let put_group ~group ~member =
    let* present = exists group in
    if present then Lwt.return_unit else write_group group member

  (* Every chunk here is re-fetchable, so holding the store under [C.max_cache]
     needs no residency, open counts or dirty checks. *)

  let root () = Cache_layout.chunks_dir ~cache_root:C.cache_root C.domain_name

  (* One budget for the store, not per sweep: [stats] is answered per status
     request, so a per-call bound would limit each sweep and none of them
     together.

     Held around a stat only, the directory holding it being {!dir_slots}'s to
     bound: one pool across both levels deadlocks, every slot held by a
     directory whose entries are waiting for one. *)
  let metadata_slots = Lwt_bounded.create ~max:64 ()

  (* The shard directories, which is a caller-sized fan-out of its own: the
     cache is split {!Chunk_layout.shards} ways, and [readdir_list] holds an
     open directory and its whole name list. Its own pool rather than
     [metadata_slots], which the entries inside each directory take from —
     nesting one pool inside itself deadlocks. *)
  let dir_slots = Lwt_bounded.create ~max:16 ()

  (* (path, bytes, mtime) per chunk body. Stat'd in parallel: one at a time is a
     round trip each, milliseconds against seconds on a few thousand chunks. *)
  let entries () =
    let* dirs = Fs_util.readdir_list (root ()) in
    let+ per_dir =
      Lwt_bounded.map_with dir_slots
        (fun dir ->
          let dir = Filename.concat (root ()) dir in
          let* names = Fs_util.readdir_list dir in
          Lwt_bounded.filter_map_with metadata_slots
            (fun name ->
              let path = Filename.concat dir name in
              Lwt.catch
                (fun () ->
                  let+ st = Lwt_unix_retry.stat path in
                  Some (path, st.Unix.st_size, st.Unix.st_mtime))
                (fun _ -> Lwt.return_none))
            names)
        dirs
    in
    List.concat per_dir

  let stats () =
    Lwt.catch
      (fun () ->
        let+ items = entries () in
        ( List.length items,
          List.fold_left (fun acc (_, bytes, _) -> acc + bytes) 0 items ))
      (fun _ -> Lwt.return (0, 0))

  (* Coldest first. Best-effort: a chunk deleted under an in-flight read is
     fetched again ({!body}). *)
  let enforce_cap () =
    match C.max_cache with
      | None -> Lwt.return_unit
      | Some cap ->
          let* items = Lwt.catch entries (fun _ -> Lwt.return_nil) in
          let total =
            List.fold_left (fun acc (_, bytes, _) -> acc + bytes) 0 items
          in
          if total <= cap then Lwt.return_unit
          else (
            let coldest =
              List.sort (fun (_, _, a) (_, _, b) -> compare a b) items
            in
            let rec go total = function
              | [] -> Lwt.return_unit
              | _ when total <= cap -> Lwt.return_unit
              | (path, bytes, _) :: rest ->
                  Log.debug "chunk cache: dropping %s (%d bytes)"
                    (Filename.basename path) bytes;
                  let* () = Fs_util.unlink_quiet path in
                  go (total - bytes) rest
            in
            go total coldest)

  let forget ~group = Fs_util.unlink_quiet (path group)

  (* Adopt [src] as this group's body by giving the same bytes a second name.
     The cache owns where a group body lives, so the staged half hands over the
     file rather than the destination.

     Not every cache root can hold a second name for one inode -- some Android
     storage goes through a shim that cannot -- and the answer is the same for
     every group once it is known, so it is asked once and remembered. Errors
     that are per-inode or transient leave it unanswered. *)
  let links_supported = ref None

  let link_in ~src ~group =
    if !links_supported = Some false then Lwt.return_false
    else (
      let dst = path group in
      Lwt.catch
        (fun () ->
          let* () = Fs_util.ensure_parent dst in
          let* () = Lwt_unix_retry.link src dst in
          let now = Unix.gettimeofday () in
          (* Dated now, or the cap reads a freshly published group as being as
             old as the write that staged it. *)
          let+ () =
            Lwt.catch
              (fun () -> Lwt_unix.utimes dst now now)
              (fun _ -> Lwt.return_unit)
          in
          links_supported := Some true;
          true)
        (function
          | Unix.Unix_error (Unix.EEXIST, _, _) ->
              links_supported := Some true;
              Lwt.return_true
          | Unix.Unix_error
              ((Unix.EPERM | Unix.ENOSYS | Unix.EOPNOTSUPP | Unix.EXDEV), _, _)
            as exn ->
              Log.info "chunk cache: publishing by link unavailable (%s)"
                (Printexc.to_string exn);
              links_supported := Some false;
              Lwt.return_false
          | _ -> Lwt.return_false))

  (* The cap may delete a group between the fetch and the read, or mid-read, so a
     miss or short read is retried once against a freshly fetched body. A second
     failure is real and raised. *)
  let read_into ~group ~index buf ~chunk_off =
    let want = Bigarray.Array1.dim buf in
    let offset = Int64.of_int (Manifest.Group.offset group index + chunk_off) in
    let attempt () = Local_io.read (path group) buf ~offset in
    (* A refetch went to a backend by construction, whatever the first [ensure]
       answered. *)
    let refetch () =
      let* _ = ensure_fetched ~force:true ~group () in
      let+ n = attempt () in
      { bytes = n; from_backend = true }
    in
    let* from_backend = ensure_fetched ~group () in
    Lwt.catch
      (fun () ->
        let* n = attempt () in
        if n = want then Lwt.return { bytes = n; from_backend } else refetch ())
      (function
        | Unix.Unix_error (Unix.ENOENT, _, _) -> refetch ()
        | exn -> Lwt.fail exn)
end
