open Lwt.Syntax

let mkdir_p = Fs_util.mkdir_p
let readdir_list = Fs_util.readdir_list

(* Each write stages to its own temp file and renames it into place, so
   overlapping writes of one key never expose a partial file.

   The name comes from {!Fs_util.temp_path} rather than being spelled here so
   that {!Fs_util.is_temp_name} recognises it: the collector parses every name
   in a namespace, and a write in flight it cannot identify stops the whole
   collection. *)
let write_file path data =
  let* () = Fs_util.ensure_parent path in
  let tmp = Fs_util.temp_path path in
  let* () = Chunk.write_to ~path:tmp data ~offset:0 in
  Lwt_unix_retry.rename tmp path

let write_string path data = write_file path (Chunk.of_string data)

(* Mapped, not read: a name here is only ever replaced by {!write_file}'s
   rename, so a mapping keeps serving the bytes it was made from however the
   name is reused afterwards, and a chunk body never lands on the heap. *)
let read_file path =
  let+ st = Lwt_unix_retry.LargeFile.stat path in
  Chunk.map_file ~path ~offset:0 ~len:(Int64.to_int st.Unix.LargeFile.st_size)

(* [link] rather than [rename]: rename replaces silently, link fails with EEXIST
   when the destination is taken, which is the whole point.

   The temp file is written first, so the claim that wins is complete the
   instant it appears. *)
let create_exclusive path data =
  let* () = Fs_util.ensure_parent path in
  let tmp = Fs_util.temp_path path in
  let* () = Chunk.write_to ~path:tmp data ~offset:0 in
  Lwt.finalize
    (fun () ->
      Lwt.catch
        (fun () ->
          let+ () = Lwt_unix_retry.link tmp path in
          data)
        (function
          | Unix.Unix_error (Unix.EEXIST, _, _) -> read_file path
          | exn -> Lwt.fail exn))
    (fun () -> Fs_util.unlink_quiet tmp)

(* A marker's shard directory exists only to hold markers, so an emptied one is
   residue — and residue that shows up in a listing of the prefix as an entry
   naming no chunk. Pruned wherever a marker goes away: cleared by a good write,
   or deleted with the chunk it accused when a collection discards it.

   Best effort both ways: a marker landing concurrently recreates the directory,
   and a shard still holding one refuses to go. *)
let prune_marker_dirs marker_path =
  let rmdir path =
    Lwt.catch (fun () -> Lwt_unix_retry.rmdir path) (fun _ -> Lwt.return_unit)
  in
  (* Up as far as the namespace root: a marker sits at
     [corrupted/<domain>/<shard>/<key>], so three levels exist only to hold it.
     Each rmdir fails harmlessly while anything is still filed below. *)
  let rec up n path =
    if n = 0 then Lwt.return_unit
    else
      let* () = rmdir path in
      up (n - 1) (Filename.dirname path)
  in
  up 3 (Filename.dirname marker_path)

(* Shared by every walk on this store: a per-call bound limits one walk, not how
   many run at once, and what is protected is the one device under the store.

   Held around the stat alone, since a shared bound held across this walk's
   recursion deadlocks: outer levels hold every slot while inner levels wait for
   one. *)
let walk_fanout = 64

(* A device error, a full disk or an exhausted descriptor table clears once the
   condition does; a permissions or read-only-mount problem needs someone to act
   before the same write can succeed. *)
let of_errno ~op key e =
  let kind =
    match e with
      | Unix.EIO | Unix.ENOSPC | Unix.EMFILE | Unix.ENFILE | Unix.EAGAIN
      | Unix.EINTR | Unix.EBUSY ->
          Backend.Transient
      | _ -> Backend.Permanent
  in
  (* The store's name is in [op]: a domain has several backends, and which one
     failed is the first thing a report needs. *)
  Backend.failed ~kind ~op:("local " ^ op) (key ^ ": " ^ Unix.error_message e)

let make ?(verify_writes = true) ~root () : (module Backend.S) =
  let walk_slots = Lwt_bounded.create ~max:walk_fanout () in
  let resolve key = if key = "" then root else Filename.concat root key in
  (* Keys with a trailing slash are directory markers: S3 stores them as
     zero-byte objects, here they map to actual directories. *)
  let is_dir_key key =
    String.length key > 0 && key.[String.length key - 1] = '/'
  in
  (* What the bucket's object-created function does for s3 and gcs, done here
     because a filesystem has no event source to hang it on. In the driver rather
     than in the uploader so that it covers every way a chunk lands — a client
     PUTting through the http-proxy frontend, a mirror, a repair's rewrite, a
     deferred forward — none of which go through {!Remote.put_chunk}.

     Read back, never hashed from [data]: what this catches is a body that did
     not survive the write, and [data] may alias a buffer its owner has already
     moved on from, so hashing the argument would agree with itself and see
     nothing.

     Verify then act, where the cloud side deletes the marker first: there the
     events are at-least-once and unordered, here we are the writer and the
     rename has already happened. *)
  let verify_written key =
    match Chunk_layout.marker_key key with
      | None -> Lwt.return_unit
      | Some marker -> (
          let* stored =
            (* Not allowed to fail the write. The bytes are on the disk — the
               rename already happened — and a read that will not come back is
               itself the finding, which on a failing disk is [EIO] rather than
               wrong bytes. Raising here would turn a fault worth recording into
               an upload error, and lose the record. *)
            Lwt.catch
              (fun () ->
                let+ body = read_file (resolve key) in
                `Body body)
              (fun exn -> Lwt.return (`Unreadable (Printexc.to_string exn)))
          in
          match stored with
            | `Unreadable why ->
                Log.err "chunk %s could not be read back (%s): filing %s"
                  (Filename.basename key) why marker;
                write_string (resolve marker)
                  (Corruption_marker.to_string
                     {
                       computed = None;
                       size = None;
                       at = Some (Unix.gettimeofday ());
                       reason = Some why;
                     })
            | `Body stored ->
                let computed = Chunk_layout.key_of_body stored in
                if computed = Filename.basename key then
                  (* The unlink happens either way, so asking whether it
                     removed anything is free — and only then is there a
                     directory worth pruning. *)
                  let* cleared =
                    Lwt.catch
                      (fun () ->
                        let+ () = Lwt_unix_retry.unlink (resolve marker) in
                        true)
                      (fun _ -> Lwt.return_false)
                  in
                  if cleared then prune_marker_dirs (resolve marker)
                  else Lwt.return_unit
                else (
                  Log.err "chunk %s hashed to %s: filing %s"
                    (Filename.basename key) computed marker;
                  write_string (resolve marker)
                    (Corruption_marker.to_string
                       {
                         computed = Some computed;
                         size = Some (Chunk.length stored);
                         at = Some (Unix.gettimeofday ());
                         reason = None;
                       })))
  in
  (module struct
    let put ~key ~data () =
      if is_dir_key key then mkdir_p (resolve key)
      else
        let* () = write_file (resolve key) data in
        if verify_writes then verify_written key else Lwt.return_unit

    let put_if_absent ~key ~data () =
      Lwt.catch
        (fun () -> create_exclusive (resolve key) data)
        (function
          | Unix.Unix_error (e, _, _) ->
              Lwt.fail (of_errno ~op:"put_if_absent" key e)
          | exn -> Lwt.fail exn)

    let get ~key () =
      Lwt.catch
        (fun () -> read_file (resolve key))
        (function
          | Unix.Unix_error (e, _, _) -> Lwt.fail (of_errno ~op:"get" key e)
          | exn -> Lwt.fail exn)

    let get_opt ~key () =
      Lwt.catch
        (fun () ->
          let+ data = read_file (resolve key) in
          Some data)
        (function
          | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_none
          | Unix.Unix_error (e, _, _) -> Lwt.fail (of_errno ~op:"get_opt" key e)
          | exn -> Lwt.fail exn)

    let head_opt ~key () =
      Lwt.catch
        (fun () ->
          let+ st = Lwt_unix_retry.stat (resolve key) in
          match st with
            | { Unix.st_kind = Unix.S_DIR; st_mtime; _ } ->
                Some Backend.{ key; size = 0; last_modified = st_mtime }
            | { Unix.st_size; st_mtime; _ } ->
                Some Backend.{ key; size = st_size; last_modified = st_mtime })
        (function
          | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_none
          | exn -> Lwt.fail exn)

    let delete ~key () =
      let* () = Fs_util.rm_rf (resolve key) in
      (* A collection deletes a chunk's marker along with the chunk ({!Gc}), and
         that is the other way a shard empties. *)
      if Chunk_layout.is_marker_key key then prune_marker_dirs (resolve key)
      else Lwt.return_unit

    let delete_multi keys = Lwt_list.iter_s (fun key -> delete ~key ()) keys

    (* A hard link when the filesystem allows one, so copying within a store
       costs a directory entry instead of the body, and the body only where there
       are no links to be had. Nothing on the collection path depends on which:
       {!Chunk_space} moves chunks rather than copying them, precisely so a
       filesystem without links does not turn a collection into a rewrite of the
       whole live set.

       Safe because a name here is only ever replaced by [write_file]'s rename,
       never written through, so two names sharing an inode cannot observe each
       other.

       The link is attempted before the destination's directory is made sure of:
       almost every copy lands in a directory that already exists, and on the
       paths that copy in bulk that stat is a third to a half of the whole
       cost. *)
    let copy ~src_key ~dst_key () =
      if is_dir_key src_key then mkdir_p (resolve dst_key)
      else (
        let src = resolve src_key and dst = resolve dst_key in
        let body () =
          let* data = read_file src in
          let* () = Fs_util.ensure_parent dst in
          write_file dst data
        in
        let rec attempt ~parent_made =
          Lwt.catch
            (fun () -> Lwt_unix_retry.link src dst)
            (function
              | Unix.Unix_error (Unix.EEXIST, _, _) -> Lwt.return_unit
              (* Either the source is gone or the destination has nowhere to be.
                 One retry tells them apart, and the second failure is the
                 source's. *)
              | Unix.Unix_error (Unix.ENOENT, _, _) when not parent_made ->
                  let* () = Fs_util.ensure_parent dst in
                  attempt ~parent_made:true
              (* Different device, link count exhausted, or a filesystem that has
                 no links to give. *)
              | Unix.Unix_error ((Unix.EXDEV | Unix.EMLINK | Unix.EPERM), _, _)
              | Unix.Unix_error (Unix.EOPNOTSUPP, _, _) ->
                  body ()
              | exn -> Lwt.fail exn)
        in
        attempt ~parent_made:false)

    let list_prefix ?max_keys ~prefix () =
      let base = resolve prefix in
      (* Entries are stat'd and subdirs recursed in parallel, so on high-latency
         storage the walk costs a few round trips per level rather than one per
         entry. *)
      let rec walk path key_prefix =
        Lwt.catch
          (fun () ->
            let* names = readdir_list path in
            let+ nested =
              Lwt_list.map_p
                (fun entry ->
                  let full_path = Filename.concat path entry in
                  let full_key = key_prefix ^ entry in
                  Lwt.catch
                    (fun () ->
                      (* The slot covers the stat only: held across the recursion
                         below, a deep tree parks every slot in an outer level
                         while inner levels wait for the same budget. *)
                      let* st =
                        Lwt_bounded.use walk_slots (fun () ->
                            Lwt_unix_retry.stat full_path)
                      in
                      match st.Unix.st_kind with
                        | Unix.S_REG ->
                            Lwt.return
                              [
                                Backend.
                                  {
                                    key = full_key;
                                    size = st.Unix.st_size;
                                    last_modified = st.Unix.st_mtime;
                                  };
                              ]
                        | Unix.S_DIR -> walk full_path (full_key ^ "/")
                        | _ -> Lwt.return [])
                    (function
                      | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return []
                      | exn -> Lwt.fail exn))
                names
            in
            let entries = List.concat nested in
            (* Empty directories surface as their marker key, matching the
               zero-byte object S3 lists. *)
            if names = [] && is_dir_key key_prefix then
              [Backend.{ key = key_prefix; size = 0; last_modified = 0. }]
            else entries)
          (function
            | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_nil
            | Unix.Unix_error (Unix.ENOTDIR, _, _) ->
                Lwt.catch
                  (fun () ->
                    let+ st = Lwt_unix_retry.stat base in
                    [
                      Backend.
                        {
                          key = prefix;
                          size = st.Unix.st_size;
                          last_modified = st.Unix.st_mtime;
                        };
                    ])
                  (fun _ -> Lwt.return_nil)
            | exn -> Lwt.fail exn)
      in
      let+ entries = walk base prefix in
      let entries =
        List.sort
          (fun a b -> String.compare a.Backend.key b.Backend.key)
          entries
      in
      match max_keys with
        | Some n when List.length entries > n ->
            List.filteri (fun i _ -> i < n) entries
        | _ -> entries

    (* Probed once: the device under a configured root does not change, and this
       is asked with a request waiting on the answer. *)
    let concurrency = lazy (Device.max_concurrency root)

    (* A filesystem has nothing on its side to wake. Every write is already
       checked as it lands ({!verify_written}), and [tsync gc --verify] is the
       sweep over what is already there. *)
    let verify_all ~chunk_prefix:_ () = Lwt.return `Unsupported

    (* Nothing to wake here either, and a collection deleting on a filesystem is
       already deleting on the machine it runs on. *)
    let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
      Lwt.return `Unsupported

    (* [gc]: a filesystem has the one thing collecting chunks takes, which is
       [rename] — of a directory to open a run, and within it to mark. True of
       every filesystem, not only the ones with hard links to give.

       [verified]: this store checks each chunk as it takes it, so its
       [corrupted/] prefix is a live answer rather than an empty prefix nobody
       writes. False when the operator turned that off, since a listing that
       finds nothing would otherwise read as a clean bill of health. *)
    let capabilities ~prefix:_ () =
      Lwt.return
        {
          Backend.no_caps with
          max_concurrency = Lazy.force concurrency;
          gc = true;
          verified = verify_writes;
        }
  end)

let spec =
  Field_spec.
    [
      {
        name = "path";
        label = "Local path";
        typ = `String;
        default = None;
        secret = false;
      };
      {
        name = "verifyWrites";
        label = "Hold each chunk against its own name as it is written";
        typ = `Bool;
        default = Some "true";
        secret = false;
      };
    ]

let () =
  Backend.register ~spec "local" (fun get ->
      let root =
        match get "path" with
          | Some p -> p
          | None -> failwith "local backend: missing field: path"
      in
      (* Costs one read back per chunk written, usually from page cache. Off is
         for a store whose throughput matters more than knowing early — the
         chunks are still checked wherever else they land. *)
      let verify_writes = Field_spec.bool ~default:true (get "verifyWrites") in
      make ~verify_writes ~root ())
