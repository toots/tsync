(* What a store on a filesystem needs below it. *)
module type FS = sig
  type 'a io

  val mkdir_p : string -> unit io
  val ensure_parent : string -> unit io
  val readdir_list : string -> string list io
  val rm_rf : string -> unit io
  val unlink_quiet : string -> unit io
end

module type SYSCALLS = sig
  type 'a io

  val stat : string -> Unix.stats io
  val link : string -> string -> unit io
  val rename : string -> string -> unit io
  val unlink : string -> unit io
  val rmdir : string -> unit io

  module LargeFile : sig
    val stat : string -> Unix.LargeFile.stats io
  end
end

module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val use : t -> (unit -> 'a io) -> 'a io
  val each : width:int -> (unit -> (unit -> unit io) option) -> unit io
end

module type WALL_CLOCK = sig
  val now : unit -> float
end

(* Being told a directory changed. [None] from [open_dir] is a directory this
   platform or filesystem will not watch, which is not a failure: the caller
   goes back to asking on a timer. *)
module type WATCHER = sig
  type 'a io
  type t

  val open_dir : string -> t option
  val wait : t -> unit io
end

(* Writing a buffer straight to a path, which the bigstring layer owns. *)
module type BYTES = sig
  type 'a io

  val write_to : path:string -> Bigstring.t -> offset:int -> unit io
end

module Over
    (Io : Io.S)
    (Fs : FS with type 'a io := 'a Io.t)
    (Sys : SYSCALLS with type 'a io := 'a Io.t)
    (Bounded : POOLS with type 'a io := 'a Io.t)
    (Bytes : BYTES with type 'a io := 'a Io.t)
    (Wall : WALL_CLOCK)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Watcher : WATCHER with type 'a io := 'a Io.t) =
struct
  module type Store = Backend.S with type 'a io := 'a Io.t

  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x
  let return_unit = Io.return ()
  let return_false = Io.return false

  let rec iter_s f = function
    | [] -> return_unit
    | x :: rest -> Io.bind (f x) (fun () -> iter_s f rest)

  let mkdir_p = Fs.mkdir_p
  let readdir_list = Fs.readdir_list

  (* Each write stages to its own temp file and renames it into place, so
     overlapping writes of one key never expose a partial file.

     The name comes from {!Filename.temp_path} rather than being spelled here so
     that {!Filename.is_temp_name} recognises it: the collector parses every name
     in a namespace, and a write in flight it cannot identify stops the whole
     collection. *)
  let write_file path data =
    let* () = Fs.ensure_parent path in
    let tmp = Filename.temp_path path in
    let* () = Bytes.write_to ~path:tmp data ~offset:0 in
    Sys.rename tmp path

  let write_string path data = write_file path (Bigstring.of_string data)

  (* Mapped, not read: a name here is only ever replaced by {!write_file}'s
     rename, so a mapping keeps serving the bytes it was made from however the
     name is reused afterwards, and a chunk body never lands on the heap. *)
  let read_file path =
    let+ st = Sys.LargeFile.stat path in
    Bigstring.map_file ~path ~offset:0
      ~len:(Int64.to_int st.Unix.LargeFile.st_size)

  (* [link] rather than [rename]: rename replaces silently, link fails with EEXIST
     when the destination is taken, which is the whole point.

     The temp file is written first, so the claim that wins is complete the
     instant it appears. *)
  let create_exclusive path data =
    let* () = Fs.ensure_parent path in
    let tmp = Filename.temp_path path in
    let* () = Bytes.write_to ~path:tmp data ~offset:0 in
    Io.finalize
      (fun () ->
        Io.catch
          (fun () ->
            let+ () = Sys.link tmp path in
            data)
          (function
            | Unix.Unix_error (Unix.EEXIST, _, _) -> read_file path
            | exn -> Io.fail exn))
      (fun () -> Fs.unlink_quiet tmp)

  (* A marker's shard directory exists only to hold markers, so an emptied one is
     residue — and residue that shows up in a listing of the prefix as an entry
     naming no chunk. Pruned wherever a marker goes away: cleared by a good write,
     or deleted with the chunk it accused when a collection discards it.

     Best effort both ways: a marker landing concurrently recreates the directory,
     and a shard still holding one refuses to go. *)
  let prune_marker_dirs marker_path =
    let rmdir path =
      Io.catch (fun () -> Sys.rmdir path) (fun _ -> return_unit)
    in
    (* Up as far as the namespace root: a marker sits at
       [corrupted/<domain>/<shard>/<key>], so three levels exist only to hold it.
       Each rmdir fails harmlessly while anything is still filed below. *)
    let rec up n path =
      if n = 0 then return_unit
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

  (* Workers, not slots: a promise per entry is the tree's size in promises, and
     every level awaiting the one below keeps the whole tree's worth of them alive
     at once -- half a million manifests came to a hundred megabytes of pending
     promises, closures and queue cells before a single key was returned.

     Nested, so what runs at once is their product, taken from the bound above
     rather than spelled as a second number that has to be kept in step with it. *)
  let dir_workers = 8
  let entry_workers = max 1 (walk_fanout / dir_workers)

  (* A device error, a full disk or an exhausted descriptor table clears once the
     condition does; a permissions or read-only-mount problem needs someone to act
     before the same write can succeed. *)
  let of_errno ~op key e =
    let kind =
      match e with
        | Unix.EIO | Unix.ENOSPC | Unix.EMFILE | Unix.ENFILE | Unix.EAGAIN
        | Unix.EINTR | Unix.EBUSY ->
            Retry.Transient
        | _ -> Retry.Permanent
    in
    (* The store's name is in [op]: a domain has several backends, and which one
       failed is the first thing a report needs. *)
    Retry.failed ~kind ~op:("local " ^ op) (key ^ ": " ^ Unix.error_message e)

  let make ?(verify_writes = true) ~root () : (module Store) =
    let walk_slots = Bounded.create ~max:walk_fanout () in
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
      let leaf = Filename.basename (Stored_key.to_string key) in
      let at k = resolve (Stored_key.to_string k) in
      match Chunk_layout.marker_key key with
        | None -> return_unit
        | Some marker -> (
            let* stored =
              (* Not allowed to fail the write. The bytes are on the disk — the
                 rename already happened — and a read that will not come back is
                 itself the finding, which on a failing disk is [EIO] rather than
                 wrong bytes. Raising here would turn a fault worth recording into
                 an upload error, and lose the record. *)
              Io.catch
                (fun () ->
                  let+ body = read_file (at key) in
                  `Body body)
                (fun exn -> Io.return (`Unreadable (Printexc.to_string exn)))
            in
            match stored with
              | `Unreadable why ->
                  Log.err "chunk %s could not be read back (%s): filing %s" leaf
                    why
                    (Stored_key.to_string marker);
                  write_string (at marker)
                    (Corruption_marker.to_string
                       {
                         computed = None;
                         size = None;
                         at = Some (Wall.now ());
                         reason = Some why;
                       })
              | `Body stored ->
                  let computed = Chunks.key_of_body stored in
                  if computed = leaf then
                    (* The unlink happens either way, so asking whether it
                       removed anything is free — and only then is there a
                       directory worth pruning. *)
                    let* cleared =
                      Io.catch
                        (fun () ->
                          let+ () = Sys.unlink (at marker) in
                          true)
                        (fun _ -> return_false)
                    in
                    if cleared then prune_marker_dirs (at marker)
                    else return_unit
                  else (
                    Log.err "chunk %s hashed to %s: filing %s" leaf computed
                      (Stored_key.to_string marker);
                    write_string (at marker)
                      (Corruption_marker.to_string
                         {
                           computed = Some computed;
                           size = Some (Bigstring.length stored);
                           at = Some (Wall.now ());
                           reason = None;
                         })))
    in
    (module struct
      let put ~key ~data () =
        let path = resolve (Stored_key.to_string key) in
        if Stored_key.is_dir_key key then mkdir_p path
        else
          let* () = write_file path data in
          if verify_writes then verify_written key else return_unit

      let put_if_absent ~key ~data () =
        let key = Stored_key.to_string key in
        Io.catch
          (fun () -> create_exclusive (resolve key) data)
          (function
            | Unix.Unix_error (e, _, _) ->
                Io.fail (of_errno ~op:"put_if_absent" key e)
            | exn -> Io.fail exn)

      let get ~key () =
        let key = Stored_key.to_string key in
        Io.catch
          (fun () -> read_file (resolve key))
          (function
            | Unix.Unix_error (e, _, _) -> Io.fail (of_errno ~op:"get" key e)
            | exn -> Io.fail exn)

      let get_opt ~key () =
        let key = Stored_key.to_string key in
        Io.catch
          (fun () ->
            let+ data = read_file (resolve key) in
            Some data)
          (function
            | Unix.Unix_error (Unix.ENOENT, _, _) -> Io.return None
            | Unix.Unix_error (e, _, _) ->
                Io.fail (of_errno ~op:"get_opt" key e)
            | exn -> Io.fail exn)

      (* Clamped to what the file holds, since a mapping past the end is not a
         short read but a signal on the first page touched. *)
      let fast_read = true

      let get_range ~key ~offset ~length () =
        let key = Stored_key.to_string key in
        let path = resolve key in
        Io.catch
          (fun () ->
            let+ st = Sys.LargeFile.stat path in
            let size = Int64.to_int st.Unix.LargeFile.st_size in
            let len = max 0 (min length (size - offset)) in
            Some (Bigstring.map_file ~path ~offset ~len))
          (function
            | Unix.Unix_error (Unix.ENOENT, _, _) -> Io.return None
            | Unix.Unix_error (e, _, _) ->
                Io.fail (of_errno ~op:"get_range" key e)
            | exn -> Io.fail exn)

      let head_opt ~key () =
        let path = resolve (Stored_key.to_string key) in
        Io.catch
          (fun () ->
            let+ st = Sys.stat path in
            match st with
              | { Unix.st_kind = Unix.S_DIR; st_mtime; _ } ->
                  Some
                    Backend.
                      { key; size = 0; last_modified = st_mtime; etag = None }
              | { Unix.st_size; st_mtime; _ } ->
                  Some
                    Backend.
                      {
                        key;
                        size = st_size;
                        last_modified = st_mtime;
                        etag = None;
                      })
          (function
            | Unix.Unix_error (Unix.ENOENT, _, _) -> Io.return None
            | exn -> Io.fail exn)

      let delete ~key () =
        let path = resolve (Stored_key.to_string key) in
        let* () = Fs.rm_rf path in
        (* A collection deletes a chunk's marker along with the chunk ({!Gc}), and
           that is the other way a shard empties. *)
        if Chunk_layout.is_marker_key key then prune_marker_dirs path
        else return_unit

      let delete_multi keys = iter_s (fun key -> delete ~key ()) keys

      (* A hard link when the filesystem allows one, so copying within a store
         costs a directory entry instead of the body, and the body only where there
         are no links to be had. Nothing on the collection path depends on which:
         {!Collection} moves chunks rather than copying them, precisely so a
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
        let src_key = Stored_key.to_string src_key
        and dst_key = Stored_key.to_string dst_key in
        if is_dir_key src_key then mkdir_p (resolve dst_key)
        else (
          let src = resolve src_key and dst = resolve dst_key in
          let body () =
            let* data = read_file src in
            let* () = Fs.ensure_parent dst in
            write_file dst data
          in
          let rec attempt ~parent_made =
            Io.catch
              (fun () -> Sys.link src dst)
              (function
                | Unix.Unix_error (Unix.EEXIST, _, _) -> return_unit
                (* Either the source is gone or the destination has nowhere to be.
                   One retry tells them apart, and the second failure is the
                   source's. *)
                | Unix.Unix_error (Unix.ENOENT, _, _) when not parent_made ->
                    let* () = Fs.ensure_parent dst in
                    attempt ~parent_made:true
                (* Different device, link count exhausted, or a filesystem that has
                   no links to give. *)
                | Unix.Unix_error ((Unix.EXDEV | Unix.EMLINK | Unix.EPERM), _, _)
                | Unix.Unix_error (Unix.EOPNOTSUPP, _, _) ->
                    body ()
                | exn -> Io.fail exn)
          in
          attempt ~parent_made:false)

      let list_prefix ?max_keys ~prefix () =
        let base = resolve prefix in
        let entries = ref [] in
        let emit e = entries := e :: !entries in
        (* Directories still to read, and the ones this level found. *)
        let frontier = ref [(base, prefix)] in
        let found = ref [] in
        let guard f =
          Io.catch f (function
            | Unix.Unix_error (Unix.ENOENT, _, _) -> return_unit
            | Unix.Unix_error (Unix.ENOTDIR, _, _) ->
                Io.catch
                  (fun () ->
                    let+ st = Sys.stat base in
                    emit
                      Backend.
                        {
                          key = Stored_key.listed prefix;
                          size = st.Unix.st_size;
                          last_modified = st.Unix.st_mtime;
                          etag = None;
                        })
                  (fun _ -> return_unit)
            | exn -> Io.fail exn)
        in
        let entry path key_prefix name () =
          let full_path = Filename.concat path name in
          let full_key = key_prefix ^ name in
          Io.catch
            (fun () ->
              (* The slot covers the stat alone, and the workers above hold none,
                 so nothing waits for this budget while holding it. *)
              let+ st = Bounded.use walk_slots (fun () -> Sys.stat full_path) in
              match st.Unix.st_kind with
                | Unix.S_REG ->
                    emit
                      Backend.
                        {
                          key = Stored_key.listed full_key;
                          size = st.Unix.st_size;
                          last_modified = st.Unix.st_mtime;
                          etag = None;
                        }
                | Unix.S_DIR -> found := (full_path, full_key ^ "/") :: !found
                | _ -> ())
            (function
              | Unix.Unix_error (Unix.ENOENT, _, _) -> return_unit
              | exn -> Io.fail exn)
        in
        let visit (path, key_prefix) =
          guard (fun () ->
              let* names = readdir_list path in
              (* A write in flight is not an object: {!write_file} stages under a
                 name of its own and renames, so listing one hands out a key that
                 is gone by the time anybody asks for it, and a mirror copies the
                 half-written body to every other backend under that name. *)
              let names =
                List.filter (fun n -> not (Filename.is_temp_name n)) names
              in
              (* Empty directories surface as their marker key, matching the
                 zero-byte object S3 lists. *)
              if names = [] then (
                if is_dir_key key_prefix then
                  emit
                    Backend.
                      {
                        key = Stored_key.listed key_prefix;
                        size = 0;
                        last_modified = 0.;
                        etag = None;
                      };
                return_unit)
              else (
                let rest = ref names in
                Bounded.each ~width:entry_workers (fun () ->
                    match !rest with
                      | [] -> None
                      | name :: tl ->
                          rest := tl;
                          Some (entry path key_prefix name))))
        in
        let rec levels () =
          match !frontier with
            | [] -> return_unit
            | dirs ->
                frontier := [];
                found := [];
                let rest = ref dirs in
                let* () =
                  Bounded.each ~width:dir_workers (fun () ->
                      match !rest with
                        | [] -> None
                        | dir :: tl ->
                            rest := tl;
                            Some (fun () -> visit dir))
                in
                frontier := !found;
                levels ()
        in
        let+ () = levels () in
        let entries =
          List.sort
            (fun a b -> Stored_key.compare a.Backend.key b.Backend.key)
            !entries
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
      (* A filesystem read is not a round trip: {!Backend.Make.Batched} fans these
         out. *)
      let get_many = None
      let verify_all ~chunk_prefix:_ () = Io.return `Unsupported

      (* Nothing to wake here either, and a collection deleting on a filesystem is
         already deleting on the machine it runs on. *)
      let discard ~chunk_prefix:_ ~run:_ ~name:_ ~keys:_ () =
        Io.return `Unsupported

      (* [gc]: a filesystem has the one thing collecting chunks takes, which is
         [rename] — of a directory to open a run, and within it to mark. True of
         every filesystem, not only the ones with hard links to give.

         [verified]: this store checks each chunk as it takes it, so its
         [corrupted/] prefix is a live answer rather than an empty prefix nobody
         writes. False when the operator turned that off, since a listing that
         finds nothing would otherwise read as a clean bill of health. *)
      let capabilities ~prefix:_ () =
        Io.return
          {
            Backend.no_caps with
            max_concurrency = Lazy.force concurrency;
            verified = verify_writes;
          }

      (* One per directory, held for the life of the process: a store watches
         its own root and nothing else, so opening is the whole cost.

         ponytail: never closed and never evicted, the set being the domains
         this process serves. Reclaim them if a process ever drops a store. *)
      let watchers : (string, Watcher.t) Hashtbl.t = Hashtbl.create 1

      let watcher_for dir =
        match Hashtbl.find_opt watchers dir with
          | Some watcher -> Some watcher
          | None ->
              let watcher = Watcher.open_dir dir in
              Option.iter (Hashtbl.replace watchers dir) watcher;
              watcher

      (* The directory, never the object: {!write_file} renames into place, so a
         watch on the object's own name follows an inode that is unlinked a
         moment later.

         Capped at the interval this would otherwise have slept, so an event
         that never comes — a writer on the far side of a network mount — costs
         nothing against asking, and one that does turns a wait of seconds into
         no wait at all. *)
      let watch ~key ~last_seen:_ () =
        let dir = Filename.dirname (resolve (Stored_key.to_string key)) in
        match watcher_for dir with
          | None -> Clock.sleep Backend.default_watch_interval
          | Some watcher ->
              Io.catch
                (fun () ->
                  Clock.with_timeout Backend.default_watch_interval (fun () ->
                      Watcher.wait watcher))
                (fun exn ->
                  if Clock.is_timeout exn then Io.return ()
                  else Clock.sleep Backend.default_watch_interval)

      (* Objects are files at [root/<key>] ({!resolve}), so a caller may work on
         the tree as one. *)
      let local_path = Some root
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
end
