open Lwt.Syntax

let mkdir_p = Fs_util.mkdir_p
let readdir_list = Fs_util.readdir_list

(* Each write stages to its own temp file (pid + sequence suffix) and renames it
   into place, so overlapping writes of one key never expose a partial file. Last
   rename wins. *)
let tmp_seq = ref 0

let write_file path data =
  let* () = Fs_util.ensure_parent path in
  incr tmp_seq;
  let tmp = Printf.sprintf "%s.%d.%d.tmp" path (Unix.getpid ()) !tmp_seq in
  let* () =
    Lwt_unix_retry.with_file ~mode:Lwt_io.Output tmp (fun oc ->
        Lwt_io.write oc data)
  in
  Lwt_unix_retry.rename tmp path

let read_file path =
  Lwt_unix_retry.with_file ~mode:Lwt_io.Input path Lwt_io.read

(* Claim [path] for [data], answering with whatever ends up there.

   [link] rather than [rename]: rename replaces silently, link fails with EEXIST
   when the destination is taken, which is the whole point. The temp file is
   written first, so the claim that wins is complete the instant it appears. *)
let create_exclusive path data =
  let* () = Fs_util.ensure_parent path in
  incr tmp_seq;
  let tmp = Printf.sprintf "%s.%d.%d.claim" path (Unix.getpid ()) !tmp_seq in
  let* () =
    Lwt_unix_retry.with_file ~mode:Lwt_io.Output tmp (fun oc ->
        Lwt_io.write oc data)
  in
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

(* Enough concurrent stats to hide per-call latency on high-latency storage,
   bounded so a large tree is not a descriptor storm.

   Shared by every walk on this store: a per-call bound limits one walk, not how
   many run at once, and what is protected is the one device under the store.

   Held around the stat alone. This walk recurses, and a shared bound held across
   a recursive call deadlocks: outer levels hold every slot while inner levels
   wait for one. *)
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
     failed is the first thing a report needs. Stores that retry get it from
     {!Backend.with_retry}'s [~name] instead. *)
  Backend.failed ~kind ~op:("local " ^ op) (key ^ ": " ^ Unix.error_message e)

let make ~root : (module Backend.S) =
  let walk_slots = Lwt_bounded.create ~max:walk_fanout () in
  let resolve key = if key = "" then root else Filename.concat root key in
  (* Keys with a trailing slash are directory markers: S3 stores them as
     zero-byte objects, here they map to actual directories. *)
  let is_dir_key key =
    String.length key > 0 && key.[String.length key - 1] = '/'
  in
  (module struct
    let put ~key ~data () =
      if is_dir_key key then mkdir_p (resolve key)
      else write_file (resolve key) data

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

    let delete ~key () = Fs_util.rm_rf (resolve key)
    let delete_multi keys = Lwt_list.iter_s (fun key -> delete ~key ()) keys

    (* A hard link when the filesystem allows one, so copying within a store
       costs a directory entry instead of the body. {!Chunk_space} leans on this:
       collecting chunks links a whole store's live set, and reading and
       rewriting every byte to do it would be absurd.

       Safe because a name here is only ever replaced by [write_file]'s rename,
       never written through, so two names sharing an inode cannot observe each
       other. [EEXIST] counts as success — the destination already holds these
       bytes, and a copy that has nothing left to do is done.

       The link is attempted before the destination's directory is made sure of,
       rather than after. Almost every copy lands in a directory that already
       exists, so making sure first is a stat spent to learn nothing — and on the
       paths that copy in bulk it is a third to a half of the whole cost. [ENOENT]
       is the only answer that leaves a question: create the parent, try once more,
       and let a second [ENOENT] be the missing source it then is. *)
    let copy ~src_key ~dst_key () =
      if is_dir_key src_key then mkdir_p (resolve dst_key)
      else
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
        attempt ~parent_made:false

    let list_prefix ?max_keys ~prefix () =
      let base = resolve prefix in
      (* Entries are stat'd and subdirs recursed in parallel, so on high-latency
         storage the walk costs a few round trips per level rather than one per
         entry.

         Bounded explicitly: the Lwt thread pool bounds threads, not the
         descriptors and recursion a walk holds, and a directory is as large as
         the user's data. *)
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
       is asked with a request waiting. *)
    let concurrency = lazy (Device.max_concurrency root)

    (* [gc]: a filesystem has the two things collecting chunks takes — a link
       within the store and a directory rename. *)
    let capabilities ~prefix:_ () =
      Lwt.return
        {
          Backend.no_caps with
          max_concurrency = Lazy.force concurrency;
          gc = true;
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
    ]

let () =
  Backend.register ~spec "local" (fun get ->
      let root =
        match get "path" with
          | Some p -> p
          | None -> failwith "local backend: missing field: path"
      in
      make ~root)
