open Tsync_core
open Tsync_remote
open Tsync_checkout

type content = Published of Manifest.t | Staged_edit of Staged.edit

type stat = {
  kind : [ `Dir | `File | `Symlink ];
  size : int;
  mtime : float;
  content_id : string option;
  etag : string;
  staged : bool;
  target : string option;
  folder_id : Folder_id.t option;
}

(** A transfer running now: [bytes] of [size] since [started] (wall time). *)
type transfer = { path : string; size : int; bytes : int; started : float }

type handle = {
  hid : int;
  mutable path : string;
  mutable ended : content option;
  mutable pos : int;
}

(* 04 §2.8: the file key, so a record follows its file through a folder rename. *)
type upload = {
  file : Algebra.place;
  attempts : int;
  last_error : (string * string) option;
}

let upload_key (p : Algebra.place) = Folder_id.to_string p.parent ^ "/" ^ p.name

let upload_kind =
  {
    Dqueue.decode =
      (fun body ->
        match Yojson.Safe.from_string body with
          | exception _ -> None
          | `Assoc l as json -> (
              match Log_entry.key_of_json json with
                | Ok (`File file) ->
                    Some
                      {
                        file;
                        attempts =
                          (match List.assoc_opt "attempts" l with
                            | Some (`Int n) -> n
                            | _ -> 0);
                        last_error =
                          (match List.assoc_opt "lastError" l with
                            | Some (`Assoc e) -> (
                                match
                                  ( List.assoc_opt "kind" e,
                                    List.assoc_opt "detail" e )
                                with
                                  | Some (`String k), Some (`String d) ->
                                      Some (k, d)
                                  | _ -> None)
                            | _ -> None);
                      }
                | _ -> None)
          | _ -> None);
    encode =
      (fun u ->
        Yojson.Safe.to_string
          (`Assoc
             (Log_entry.key_fields (`File u.file)
             @ [("attempts", `Int u.attempts)]
             @
               match u.last_error with
               | Some (kind, detail) ->
                   [
                     ( "lastError",
                       `Assoc
                         [("kind", `String kind); ("detail", `String detail)] );
                   ]
               | None -> [])));
    key = (fun u -> Some (upload_key u.file));
    note =
      (fun u f ->
        {
          u with
          attempts = u.attempts + 1;
          last_error = Some (Fail.kind_name f.kind, f.reason);
        });
    accepts = (fun _ -> true);
  }

(* 04 §2.8: one feed op and the ids of the files it names, read before the
   first local step. *)
let encode_intent op fids =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("op", Op.to_json op);
         ("fids", `List (List.map (fun f -> `String f) fids));
       ])

let decode_intent body =
  match Yojson.Safe.from_string body with
    | exception _ -> None
    | `Assoc l -> (
        match Option.map Op.of_json (List.assoc_opt "op" l) with
          | Some (Some op) ->
              Some
                ( op,
                  match List.assoc_opt "fids" l with
                    | Some (`List fids) ->
                        List.filter_map
                          (function `String f -> Some f | _ -> None)
                          fids
                    | _ -> [] )
          | Some None | None | (exception Op.Bad _) -> None)
    | _ -> None

module Make (C : Engine_ctx.S) = struct
  module R = Remote.Make (C)
  module T = Tree.Make (C)

  let d = C.domain
  let mirror = Mirror.create ~cache_root:C.cache_root d
  let staged = Staged.create ~cache_root:C.cache_root d
  let applied = Applied.open_ (Filename.concat (Mirror.root mirror) "applied")
  let folder_minter = Identity.minter ~data_dir:C.data_dir ~uuid:C.client_uuid
  let sync_state = Sync_state.open_ ~data_dir:C.data_dir d

  let log_dir name =
    List.fold_left Filename.concat C.data_dir [name; Domain_name.to_string d]

  let upload_log = Dqueue.Records.open_ (log_dir "uploads-pending")
  let intents = Dqueue.Records.open_ (log_dir "intents-pending")

  let cache =
    Cache.create ~cache_root:C.cache_root ~domain:d ~cc:C.cache_chunk_size
      ~fast:C.store.fast_read ~get_whole:R.get_chunk
      ~get_range:R.get_chunk_range ~cap:C.max_cache

  let () = Applied.load applied

  let feed_keys =
    Feed_key.minter ~client:C.client_uuid
      ~seen:(Option.to_list (Applied.head applied))

  let uploads =
    Dqueue.create ~workers:(max 1 C.max_uploads) ~name:"uploads" ~ordered:false
      upload_kind upload_log

  let cycle_signal = Rt.Signal.create ()
  let wake_cycle () = Rt.Signal.broadcast cycle_signal

  (* 04 §3.2: the metadata lock serialises every namespace change; each key's
     lock every content change of that key, taken after the metadata lock. *)
  let meta = Rt.Fmutex.create ()
  let klocks = Keyed_locks.create ()
  let with_key path f = Keyed_locks.with_key klocks path f

  let with_keys paths f =
    List.fold_right
      (fun p acc () -> with_key p acc)
      (List.sort_uniq compare paths)
      f ()

  let generation = Keyed_locks.generation klocks
  let bump = Keyed_locks.bump klocks
  let meta_holder = Atomic.make None

  (* Pitfall A-2.5: a long hold stalls every mutation of the domain, so one is
     reported with the place that held or waited. *)
  let slow_meta = 2.

  (* The first frame outside the lock's own code. *)
  let meta_caller () =
    let own = [__FILE__; "fun.ml"] in
    let outside slot =
      match Printexc.Slot.location slot with
        | Some l when not (List.mem l.filename own) ->
            Some (Printf.sprintf "%s:%d" l.filename l.line_number)
        | _ -> None
    in
    Option.bind
      (Printexc.backtrace_slots (Printexc.get_callstack 16))
      (Array.find_map outside)

  let report_slow_meta what seconds =
    if seconds > slow_meta then
      Log.warn "metadata lock %s %.1f s at %s" what seconds
        (Option.value ~default:"an unknown place" (meta_caller ()))

  (* Reentrant for its holder, so the request handler resolves a reference and
     acts on it in one hold (08 §3.5). *)
  let with_meta f =
    match Atomic.get meta_holder with
      | Some h when Rt.same h (Rt.self ()) -> f ()
      | _ ->
          let asked = Rt.now () in
          Rt.Fmutex.with_lock meta (fun () ->
              let taken = Rt.now () in
              report_slow_meta "waited" (taken -. asked);
              Atomic.set meta_holder (Some (Rt.self ()));
              Fun.protect
                ~finally:(fun () ->
                  Atomic.set meta_holder None;
                  report_slow_meta "held" (Rt.now () -. taken))
                f)

  let changed_hook : (string list -> unit) ref = ref (fun _ -> ())
  let changed paths = try !changed_hook paths with _ -> ()
  let handles_m = Mutex.create ()
  let handles : (int, handle) Hashtbl.t = Hashtbl.create 64
  let next_hid = Atomic.make 1
  let body_refs : (string, int) Hashtbl.t = Hashtbl.create 16
  let deferred_release : (string, unit) Hashtbl.t = Hashtbl.create 16

  let release_body id =
    Mutex.protect handles_m (fun () ->
        if Hashtbl.mem body_refs id then Hashtbl.replace deferred_release id ()
        else (
          ignore (Fs.release (Staged.body_path staged id));
          ignore (Fs.release (Staged.whole_path staged id))))

  (* Pitfall C-7.10: a body made for an edit is the edit's once the staged
     manifest naming it is written; if [f] raises, the bodies it registered
     that the manifest now on disk does not name are released. *)
  let with_new_bodies path f =
    let created = ref [] in
    match f (fun b -> created := b :: !created) with
      | v -> v
      | exception e ->
          let named =
            match Staged.edit staged path with
              | Some x -> Staged.bodies_named x
              | None -> []
          in
          List.iter
            (fun b ->
              if not (List.mem b named) then (try release_body b with _ -> ()))
            !created;
          raise e

  (* R3: bodies go only after the manifest that switched away is durable, and
     not while an ended lineage still reads them. *)
  let release_unnamed old_edit new_edit =
    let keep =
      match new_edit with Some e -> Staged.bodies_named e | None -> []
    in
    List.iter
      (fun b -> if not (List.mem b keep) then release_body b)
      (Staged.bodies_named old_edit)

  (* Holding [handles_m]. *)
  let ref_bodies_locked e delta =
    List.iter
      (fun b ->
        let n =
          Option.value ~default:0 (Hashtbl.find_opt body_refs b) + delta
        in
        if n <= 0 then Hashtbl.remove body_refs b
        else Hashtbl.replace body_refs b n)
      (Staged.bodies_named e)

  let ref_bodies e delta =
    Mutex.protect handles_m (fun () -> ref_bodies_locked e delta)

  let resolve path =
    match Staged.read staged path with
      | `Edit e -> Some (Staged_edit e)
      | `Unparseable ->
          Fail.corrupt "%s: its staged manifest cannot be decoded" path
      | `Absent -> (
          match Mirror.file mirror path with
            | `File m -> Some (Published m)
            | `Corrupt ->
                Fail.corrupt "%s: its mirror entry cannot be decoded" path
            | _ -> None)

  (* A change outside a handle's lineage freezes what the handle reads. The
     handles still open are frozen and their references taken in one hold, so a
     close in between neither misses a reference nor sees a freeze half done
     (pitfall A-2.1). *)
  let end_lineage path =
    let open_on_path () =
      Hashtbl.fold
        (fun _ h acc ->
          if h.path = path && h.ended = None then h :: acc else acc)
        handles []
    in
    if Mutex.protect handles_m (fun () -> open_on_path () <> []) then (
      let current = try resolve path with _ -> None in
      Mutex.protect handles_m (fun () ->
          List.iter
            (fun h ->
              h.ended <- current;
              match current with
                | Some (Staged_edit e) -> ref_bodies_locked e 1
                | _ -> ())
            (open_on_path ())))

  let move_handles ~src ~dst =
    Mutex.protect handles_m (fun () ->
        Hashtbl.iter
          (fun _ h ->
            if h.ended = None && Names.is_under ~dir:src h.path then
              h.path <-
                dst
                ^ String.sub h.path (String.length src)
                    (String.length h.path - String.length src))
          handles)

  let folder_id_of path = Mirror.folder_id mirror path
  let parent_id path = folder_id_of (Names.parent_of path)

  let require_parent path =
    match parent_id path with
      | Some id -> id
      | None ->
          Fail.raise_ Fail.Unprepared ~repair:"run 'tsync sync'"
            "%s: this client has not resolved its folder" (Names.parent_of path)

  let place_of path : Algebra.place =
    { parent = require_parent path; name = Names.leaf_of path }

  let place_opt path : Algebra.place option =
    Option.map
      (fun parent -> { Algebra.parent; name = Names.leaf_of path })
      (parent_id path)

  (* The path of each folder id, kept for the time of one enactment: under the
     metadata lock no folder moves but by the enactment itself, which forgets
     them when it moves one. Uploads read it from other domains. *)
  let dirs : (Folder_id.t, string option) Hashtbl.t = Hashtbl.create 64
  let dirs_kept = ref false
  let dirs_m = Mutex.create ()
  let forget_dirs () = Mutex.protect dirs_m (fun () -> Hashtbl.reset dirs)

  let keeping_dirs f =
    Mutex.protect dirs_m (fun () -> dirs_kept := true);
    Fun.protect f ~finally:(fun () ->
        Mutex.protect dirs_m (fun () ->
            dirs_kept := false;
            Hashtbl.reset dirs))

  let dir_of id =
    match
      Mutex.protect dirs_m (fun () ->
          if !dirs_kept then Hashtbl.find_opt dirs id else None)
    with
      | Some dir -> dir
      | None ->
          let dir = Mirror.key_of_id mirror id in
          Mutex.protect dirs_m (fun () ->
              if !dirs_kept then Hashtbl.replace dirs id dir);
          dir

  let path_of (p : Algebra.place) =
    Option.map (fun dir -> Names.join dir p.name) (dir_of p.parent)

  (* The value of a file key in [L]: the staged edit when there is one, else
     the mirror entry (conflict-resolution §3). *)
  let mirror_value path : Log_entry.value option =
    match Mirror.file mirror path with
      | `File m -> Some (Known m)
      | `Corrupt -> Some Unknown
      | `Dir | `Absent -> None

  let local_file path : Log_entry.value option =
    match Staged.read staged path with
      | `Edit { state = Uploaded m; _ } -> Some (Known m)
      | `Edit { state = Owed; _ } | `Unparseable -> Some Unknown
      | `Absent -> mirror_value path

  let local_folder id : Algebra.place option =
    match Mirror.key_of_id mirror id with
      | Some path when path <> "" ->
          Option.map
            (fun parent -> { Algebra.parent; name = Names.leaf_of path })
            (parent_id path)
      | _ -> None

  (* Only a local value is ever [Unknown], which [Log_entry.equal] makes
     differ from every value: read twice, it is the same by identity. *)
  let same v w = v == w || Log_entry.equal v w
  let same_file = Option.equal same

  (* publication §4.1: a before-value that [L] returned to is dropped. *)
  let settle path =
    let p = place_of path in
    match Sync_state.before_file sync_state p with
      | Some before when same_file before (local_file path) ->
          Sync_state.drop sync_state (`File p)
      | _ -> ()

  let settle_folder id =
    match Sync_state.before_folder sync_state id with
      | Some before when before = local_folder id ->
          Sync_state.drop sync_state (`Folder id)
      | _ -> ()

  let note_folder id = Sync_state.record_folder sync_state id (local_folder id)

  let feed ?fids ops =
    if ops <> [] then Applied.note ?fids applied (Feed_key.mint feed_keys) ops

  let kind path =
    if path = "" then `Dir
    else (
      match Mirror.kind mirror path with
        | `Dir -> `Dir
        | `File -> `File
        | `Absent -> if Staged.edit staged path <> None then `File else `Absent)

  let stat_of_manifest (m : Manifest.t) =
    {
      kind = (if m.link <> None then `Symlink else `File);
      size = m.size;
      mtime = m.mtime;
      content_id = Some m.h1;
      etag = m.h1;
      staged = false;
      target = m.link;
      folder_id = None;
    }

  (* The digest an upload of the body with chunk size [cs] yields. *)
  let digest_of_body ~size ~cs body =
    try
      let fd = Fs.openfile (Staged.whole_path staged body) [O_RDONLY] in
      Fs.with_fd fd (fun fd ->
          let n = Chunking.manifest_count ~size ~cs in
          let buf = Bigstring.create cs in
          let keys =
            List.init n (fun i ->
                let len = if size = 0 then 0 else Chunking.length ~size ~cs i in
                let got = Fs.pread_full fd buf ~boff:0 ~len ~off:(i * cs) in
                Chunk_key.of_bigstring ~len:got buf)
          in
          Some (fst (Manifest.digest_of ~size ~cs keys)))
    with _ -> None

  (* 04 §2.5: recorded at adoption; computed only for a manifest without it. *)
  let whole_digest e =
    match e.Staged.content with
      | Whole { h1 = Some h; _ } -> Some h
      | Whole { body; h1 = None } ->
          digest_of_body ~size:e.size ~cs:e.chunk_size body
      | Slots _ -> None

  let content_id path =
    match resolve path with
      | Some (Published m) -> Some m.h1
      | Some (Staged_edit { state = Uploaded m; _ }) -> Some m.h1
      | Some (Staged_edit e) -> whole_digest e
      | None -> None

  let stat path =
    match kind path with
      | `Dir ->
          {
            kind = `Dir;
            size = 0;
            mtime = Mirror.dir_mtime mirror path;
            content_id = None;
            etag = "";
            staged = false;
            target = None;
            folder_id = Mirror.folder_id mirror path;
          }
      | `Absent -> Fail.absent "%s: no such file or folder" path
      | `File -> (
          match resolve path with
            | Some (Published m) -> stat_of_manifest m
            | Some (Staged_edit e) ->
                {
                  kind = `File;
                  size = e.size;
                  mtime = e.mtime;
                  content_id =
                    (match e.state with
                      | Uploaded m -> Some m.h1
                      | Owed -> whole_digest e);
                  etag = "";
                  staged = true;
                  target = None;
                  folder_id = None;
                }
            | None -> Fail.absent "%s: no such file" path)

  type entry = { name : string; is_dir : bool; st : stat }

  (* A staged edit wins over the published entry of its path, and a staged-only
     file is listed. *)
  let list_children path =
    let published = Mirror.list mirror path in
    let from_mirror =
      List.map
        (fun (c : Mirror.child) ->
          match c.kind with
            | `Dir id ->
                {
                  name = c.name;
                  is_dir = true;
                  st = { (stat (Names.join path c.name)) with folder_id = id };
                }
            | `File m -> (
                let p = Names.join path c.name in
                match Staged.edit staged p with
                  | Some _ -> { name = c.name; is_dir = false; st = stat p }
                  | None ->
                      { name = c.name; is_dir = false; st = stat_of_manifest m }
                ))
        published
    in
    let names = List.map (fun (c : Mirror.child) -> c.name) published in
    let staged_only =
      List.filter_map
        (fun (p, _) ->
          if Names.parent_of p = path && not (List.mem (Names.leaf_of p) names)
          then Some { name = Names.leaf_of p; is_dir = false; st = stat p }
          else None)
        (Staged.edits_under staged path)
    in
    List.sort (fun a b -> compare a.name b.name) (from_mirror @ staged_only)

  let rec list_tree path =
    List.concat_map
      (fun e ->
        if e.is_dir then list_tree (Names.join path e.name)
        else [(Names.join path e.name, e.st)])
      (list_children path)

  let readlink path =
    match resolve path with
      | Some (Published { link = Some l; _ }) -> l
      | Some _ -> Fail.invalid "%s is not a symbolic link" path
      | None -> Fail.absent "%s: no such file" path

  let base_chunk (base : Manifest.t) i ~off ~len =
    let g =
      Cache.group_of ~cc:(Cache.cc cache) base
        (Cache.group_index ~cc:(Cache.cc cache) base i)
    in
    let x = List.find (fun (x : Cache.member) -> x.index = i) g.members in
    Cache.read_piece cache g x ~coff:off ~len

  let base_of path = Mirror.manifest mirror path

  (* A live staged body can change size under a reader, so it is read by
     position, never mapped (01 §12). *)
  let read_staged path (e : Staged.edit) ~off ~len =
    let len = max 0 (min len (e.size - off)) in
    if len = 0 then Bigstring.empty
    else (
      match e.content with
        | Whole { body = b; _ } ->
            let fd = Fs.openfile (Staged.whole_path staged b) [O_RDONLY] in
            Fs.with_fd fd (fun fd ->
                let buf = Bigstring.create len in
                let n = Fs.pread_full fd buf ~boff:0 ~len ~off in
                if n < len then Fail.corrupt "%s: its staged body is short" path;
                buf)
        | Slots slots ->
            let cs = e.chunk_size in
            let count = Array.length slots in
            let pieces = Chunking.pieces ~cs ~count ~off ~len in
            let out = Bigstring.create len in
            List.iter
              (fun (pc : Chunking.piece) ->
                let dst = Bigstring.sub out ~off:pc.buf_off ~len:pc.len in
                let copy b =
                  Bigstring.blit ~src:b ~src_off:0 ~dst ~dst_off:0
                    ~len:(Bigstring.length b)
                in
                match slots.(pc.index) with
                  | Staged.Zero -> Bigarray.Array1.fill dst '\000'
                  | Staged { body; off = boff } ->
                      copy
                        (Staged.read_body staged body ~off:(boff + pc.off)
                           ~len:pc.len)
                  | Inherit -> (
                      match base_of path with
                        | Some base when pc.index < base.count ->
                            let avail =
                              Chunking.length ~size:base.size
                                ~cs:base.chunk_size pc.index
                            in
                            let from = min pc.len (max 0 (avail - pc.off)) in
                            if from > 0 then
                              copy
                                (base_chunk base pc.index ~off:pc.off ~len:from);
                            if from < pc.len then
                              Bigarray.Array1.fill
                                (Bigstring.sub dst ~off:from ~len:(pc.len - from))
                                '\000'
                        | _ ->
                            Fail.corrupt
                              "%s: chunk %d inherits from a base that lacks it"
                              path pc.index))
              pieces;
            out)

  let prefetch (m : Manifest.t) off =
    let cc = Cache.cc cache in
    if m.chunk_size > 0 && m.count > 0 then (
      let i = Chunking.index ~cs:m.chunk_size off in
      let g = Cache.group_index ~cc m (min i (m.count - 1)) in
      let groups = Cache.groups ~cc m in
      List.iteri
        (fun j (grp : Cache.group) ->
          if j >= g && j <= g + 1 && not (Cache.is_whole cache grp.gkey) then
            Rt.spawn ~name:"prefetch" (fun () ->
                try Cache.ensure_whole cache grp
                with e -> Log.debug "prefetch: %s" (Printexc.to_string e)))
        groups)

  let read_published (m : Manifest.t) ~off ~len =
    Manifest.check_readable m;
    let len = max 0 (min len (m.size - off)) in
    if len = 0 then Bigstring.empty
    else (
      let pieces = Chunking.pieces ~cs:m.chunk_size ~count:m.count ~off ~len in
      let cc = Cache.cc cache in
      Bigstring.concat
        (List.map
           (fun (pc : Chunking.piece) ->
             let g = Cache.group_of ~cc m (Cache.group_index ~cc m pc.index) in
             let x =
               List.find
                 (fun (x : Cache.member) -> x.index = pc.index)
                 g.members
             in
             Cache.read_piece cache g x ~coff:pc.off ~len:pc.len)
           pieces))

  let read_content path c ~off ~len =
    match c with
      | Published m -> read_published m ~off ~len
      | Staged_edit e -> read_staged path e ~off ~len

  let open_read path =
    if resolve path = None then Fail.absent "%s: no such file" path;
    let h =
      { hid = Atomic.fetch_and_add next_hid 1; path; ended = None; pos = -1 }
    in
    Mutex.protect handles_m (fun () -> Hashtbl.replace handles h.hid h);
    h

  let retain path =
    let h = open_read path in
    end_lineage path;
    h

  let read h ~off ~len =
    let c =
      match h.ended with
        | Some c -> c
        | None -> (
            match resolve h.path with
              | Some c -> c
              | None -> Fail.absent "%s: no such file" h.path)
    in
    let s = read_content h.path c ~off ~len in
    (match c with
      | Published m when h.pos = off -> prefetch m (off + Bigstring.length s)
      | _ -> ());
    h.pos <- off + Bigstring.length s;
    s

  let close_read h =
    let h =
      Mutex.protect handles_m (fun () ->
          let x = Hashtbl.find_opt handles h.hid in
          Hashtbl.remove handles h.hid;
          x)
    in
    match h with
      | Some { ended = Some (Staged_edit e); _ } ->
          ref_bodies e (-1);
          let still =
            Mutex.protect handles_m (fun () ->
                List.filter
                  (fun b ->
                    Hashtbl.mem deferred_release b
                    && not (Hashtbl.mem body_refs b))
                  (Staged.bodies_named e))
          in
          List.iter
            (fun b ->
              Mutex.protect handles_m (fun () ->
                  Hashtbl.remove deferred_release b);
              release_body b)
            still
      | _ -> ()

  let release = close_read

  (* 04 §4.7: every step idempotent; bodies go last so a reader of either
     representation still finds its bytes. *)
  let promote_held path =
    match Staged.edit staged path with
      | Some ({ state = Uploaded m; _ } as e) ->
          (match e.content with
            | Slots slots ->
                let cc = Cache.cc cache in
                List.iter
                  (fun (g : Cache.group) ->
                    let states =
                      List.map
                        (fun (x : Cache.member) ->
                          if x.index < Array.length slots then slots.(x.index)
                          else Staged.Zero)
                        g.members
                    in
                    let staged_members =
                      List.filter
                        (function Staged.Staged _ -> true | _ -> false)
                        states
                    in
                    if
                      staged_members <> []
                      && not (List.exists (( = ) Staged.Inherit) states)
                    then (
                      let one_body =
                        match staged_members with
                          | Staged.Staged { body; _ } :: _ ->
                              List.for_all2
                                (fun (x : Cache.member) st ->
                                  match st with
                                    | Staged.Staged { body = b; off } ->
                                        b = body && off = x.off
                                    | _ -> true)
                                g.members states
                              |> fun ok -> if ok then Some body else None
                          | _ -> None
                      in
                      match one_body with
                        | Some body when Staged.body_links staged body = 1 ->
                            let fd = Staged.open_body staged body in
                            Fs.with_fd fd (fun fd ->
                                Fs.sys (fun () ->
                                    Unix.LargeFile.ftruncate fd
                                      (Int64.of_int g.gsize));
                                Fs.fsync fd);
                            Cache.adopt_body cache g.gkey
                              (Staged.body_path staged body)
                        | _ ->
                            let data =
                              Bigstring.concat
                                (List.map
                                   (fun (x : Cache.member) ->
                                     read_staged path e
                                       ~off:(x.index * m.chunk_size) ~len:x.len)
                                   g.members)
                            in
                            let tmp =
                              Fs.write_temp_bigstring
                                (Filename.dirname (Staged.body_path staged "x"))
                                data
                            in
                            Fun.protect
                              ~finally:(fun () -> Fs.unlink_quiet tmp)
                              (fun () -> Cache.adopt_body cache g.gkey tmp)))
                  (Cache.groups ~cc m)
            | Whole _ -> ());
          Mirror.write_file ~own:true mirror path m;
          end_lineage path;
          Staged.remove staged path;
          release_unnamed e None
      | _ -> ()

  let promote path = with_key path (fun () -> promote_held path)

  (* 04 §4.3: an Uploaded edit of a clean key was committed and is promoted
     before the key changes; then the key's before-value is recorded. *)
  let begin_change ?durable path =
    let p = place_of path in
    if Sync_state.before_file sync_state p = None then (
      promote_held path;
      Sync_state.record_file ?durable sync_state p (mirror_value path))

  let size_of path =
    match resolve path with
      | Some (Published m) -> m.size
      | Some (Staged_edit e) -> e.size
      | None -> 0

  (* 04 §4.3 [staged_for]: a whole edit is split before any byte-level edit. *)
  let rec staged_for path =
    match Staged.read staged path with
      | `Unparseable ->
          Fail.corrupt "%s: its staged manifest cannot be decoded" path
      | `Edit ({ content = Whole { body = b; _ }; _ } as e) ->
          let cs = C.chunk_size_config |> Option.value ~default:e.chunk_size in
          let count = Chunking.count ~size:e.size ~cs in
          let slots = Array.make count Staged.Zero in
          let per = Cache.per ~cs ~cc:C.cache_chunk_size in
          with_new_bodies path (fun register ->
              let src = Fs.openfile (Staged.whole_path staged b) [O_RDONLY] in
              Fs.with_fd src (fun src ->
                  let g = ref 0 in
                  while !g * per < count do
                    let body = Staged.new_body_id () in
                    register body;
                    let fd = Staged.open_body ~create:true staged body in
                    Fs.with_fd fd (fun fd ->
                        for j = 0 to per - 1 do
                          let i = (!g * per) + j in
                          if i < count then (
                            let len = Chunking.length ~size:e.size ~cs i in
                            let buf = Bigstring.create len in
                            let n =
                              Fs.pread_full src buf ~boff:0 ~len ~off:(i * cs)
                            in
                            Fs.pwrite_all fd buf ~boff:0 ~len:n ~off:(j * cs);
                            slots.(i) <- Staged.Staged { body; off = j * cs })
                        done;
                        Fs.fsync fd);
                    incr g
                  done);
              Fs.fsync_dir
                (Filename.concat
                   (Filename.dirname (Staged.body_path staged "x"))
                   "");
              let e' =
                { e with chunk_size = cs; content = Slots slots; state = Owed }
              in
              Staged.write staged path e');
          release_body b;
          staged_for path
      | `Edit e -> e
      | `Absent -> (
          match Mirror.file mirror path with
            | `File m when m.link = None ->
                {
                  Staged.name = Names.leaf_of path;
                  size = m.size;
                  mtime = Unix.gettimeofday ();
                  chunk_size = m.chunk_size;
                  content =
                    Slots
                      (Array.make
                         (Chunking.count ~size:m.size ~cs:m.chunk_size)
                         Staged.Inherit);
                  state = Owed;
                }
            | `Dir -> Fail.raise_ Fail.Exists "%s is a folder" path
            | _ ->
                {
                  Staged.name = Names.leaf_of path;
                  size = 0;
                  mtime = Unix.gettimeofday ();
                  chunk_size = R.chunk_size ();
                  content = Slots [||];
                  state = Owed;
                })

  let member_len ~size ~cs i = Chunking.length ~size ~cs i

  (* The bytes of member [i] as the edit holds them before the write, for the
     slow path's copy; inherited bytes come from a whole, verified body. *)
  let member_bytes path (e : Staged.edit) slots i =
    let len = member_len ~size:e.size ~cs:e.chunk_size i in
    if len <= 0 then Bigstring.empty
    else (
      match slots.(i) with
        | Staged.Zero -> Bigstring.empty
        | Staged { body; off } -> Staged.read_body staged body ~off ~len
        | Inherit -> (
            match base_of path with
              | Some base when i < base.count ->
                  let cc = Cache.cc cache in
                  let g =
                    Cache.group_of ~cc base (Cache.group_index ~cc base i)
                  in
                  let x =
                    List.find (fun (x : Cache.member) -> x.index = i) g.members
                  in
                  let s = Cache.verified_member cache g x in
                  if Bigstring.length s >= len then Bigstring.sub s ~off:0 ~len
                  else s
              | _ ->
                  Fail.corrupt "%s: chunk %d inherits from a base that lacks it"
                    path i))

  (* 04 §4.3 [ensure the group body]. *)
  let ensure_group ~register path (e : Staged.edit) slots i =
    let cs = e.chunk_size in
    let per = Cache.per ~cs ~cc:C.cache_chunk_size in
    let g = i / per in
    let first = g * per
    and last = min (Array.length slots) ((g * per) + per) - 1 in
    let members = List.init (last - first + 1) (fun j -> first + j) in
    let layout j = (j - first) * cs in
    let staged_in =
      List.filter_map
        (fun j ->
          match slots.(j) with
            | Staged.Staged { body; off } -> Some (body, off, j)
            | _ -> None)
        members
    in
    let fast =
      List.for_all (fun j -> slots.(j) <> Staged.Inherit) members
      &&
        match staged_in with
        | (b, _, _) :: _ ->
            List.for_all
              (fun (b', off, j) -> b' = b && off = layout j)
              staged_in
            && Staged.body_links staged b = 1
        | [] -> false
    in
    if fast then (
      let b = match staged_in with (b, _, _) :: _ -> b | [] -> assert false in
      List.iter
        (fun j ->
          if slots.(j) = Staged.Zero then
            slots.(j) <- Staged.Staged { body = b; off = layout j })
        members;
      [])
    else (
      let body = Staged.new_body_id () in
      register body;
      let fd = Staged.open_body ~create:true staged body in
      Fs.with_fd fd (fun fd ->
          List.iter
            (fun j ->
              let data = member_bytes path e slots j in
              if Bigstring.length data > 0 then
                Staged.write_body_at fd ~off:(layout j) data)
            members);
      let old =
        List.filter_map
          (fun j ->
            match slots.(j) with
              | Staged.Staged { body; _ } -> Some body
              | _ -> None)
          members
      in
      List.iter
        (fun j -> slots.(j) <- Staged.Staged { body; off = layout j })
        members;
      old)

  let fsync_bodies (e : Staged.edit) =
    List.iter
      (fun b ->
        let p =
          if Fs.exists (Staged.body_path staged b) then
            Staged.body_path staged b
          else Staged.whole_path staged b
        in
        match Fs.opt (fun () -> Unix.openfile p [O_RDONLY; O_CLOEXEC] 0) with
          | Some fd -> Fs.with_fd fd Fs.fsync
          | None -> ())
      (Staged.bodies_named e);
    Fs.fsync_dir (Filename.dirname (Staged.body_path staged "x"))

  (* A body the durable edit may still name is released only once the edit
     replacing it is durable, its bodies first. *)
  let write_edit ?(durable = false) ?(replaced = []) path old (e : Staged.edit)
      =
    let keep = Staged.bodies_named e in
    let gone =
      List.sort_uniq String.compare
        (List.filter
           (fun b -> not (List.mem b keep))
           (replaced @ Option.fold ~none:[] ~some:Staged.bodies_named old))
    in
    if gone = [] && not durable then Staged.write ~durable:false staged path e
    else (
      fsync_bodies e;
      Staged.write staged path e);
    List.iter release_body gone

  let dirty : (string, unit) Hashtbl.t = Hashtbl.create 16
  let dirty_m = Mutex.create ()

  let mark_dirty path =
    Mutex.protect dirty_m (fun () -> Hashtbl.replace dirty path ())

  let check_writable () =
    if C.read_only then Fail.raise_ Fail.Read_only "this domain is read-only"

  let write path ~off data =
    check_writable ();
    with_key path (fun () ->
        begin_change ~durable:false path;
        let before = Staged.edit staged path in
        let e0 = staged_for path in
        let e = e0 in
        let cs = e.chunk_size in
        let len = Bigstring.length data in
        let new_size = max e.size (off + len) in
        let n = Chunking.count ~size:new_size ~cs in
        let old_slots = Staged.slots e in
        let slots =
          Array.init n (fun i ->
              if i < Array.length old_slots then old_slots.(i) else Staged.Zero)
        in
        let e = { e with size = new_size; content = Slots slots } in
        let pieces = Chunking.pieces ~cs ~count:n ~off ~len in
        with_new_bodies path @@ fun register ->
        let replaced = ref [] in
        let fds = Hashtbl.create 2 in
        Fun.protect
          ~finally:(fun () -> Hashtbl.iter (fun _ fd -> Fs.close fd) fds)
          (fun () ->
            List.iter
              (fun (pc : Chunking.piece) ->
                replaced :=
                  ensure_group ~register path e0 slots pc.index @ !replaced;
                match slots.(pc.index) with
                  | Staged.Staged { body; off = boff } ->
                      let fd =
                        match Hashtbl.find_opt fds body with
                          | Some fd -> fd
                          | None ->
                              let fd = Staged.open_body staged body in
                              Hashtbl.replace fds body fd;
                              fd
                      in
                      Staged.write_body_at fd ~off:(boff + pc.off)
                        (Bigstring.sub data ~off:pc.buf_off ~len:pc.len)
                  | _ -> assert false)
              pieces);
        let e = { e with mtime = Unix.gettimeofday (); state = Owed } in
        write_edit ~replaced:!replaced path before e;
        bump path;
        mark_dirty path)

  let truncate path size =
    check_writable ();
    with_key path (fun () ->
        begin_change ~durable:false path;
        let before = Staged.edit staged path in
        let e = staged_for path in
        let cs = e.chunk_size in
        let n = Chunking.count ~size ~cs in
        let old = Staged.slots e in
        let slots =
          Array.init n (fun i ->
              if i < Array.length old then old.(i) else Staged.Zero)
        in
        with_new_bodies path @@ fun register ->
        let replaced = ref [] and cut = ref None in
        if n > 0 && size < e.size then (
          let last = n - 1 in
          let new_len = member_len ~size ~cs last in
          let old_len = member_len ~size:e.size ~cs last in
          match slots.(last) with
            | Staged.Inherit when new_len <> old_len -> (
                replaced := ensure_group ~register path e slots last;
                match slots.(last) with
                  | Staged.Staged { body; off } ->
                      let fd = Staged.open_body staged body in
                      Fs.with_fd fd (fun fd ->
                          if Staged.body_size staged body > off + new_len then
                            Fs.sys (fun () ->
                                Unix.LargeFile.ftruncate fd
                                  (Int64.of_int (off + new_len))))
                  | _ -> ())
            | Staged.Staged { body; off } when Staged.body_links staged body = 1
              ->
                if Staged.body_size staged body > off + new_len then
                  cut := Some (body, off + new_len)
            | Staged.Staged _ ->
                replaced := ensure_group ~register path e slots last
            | _ -> ());
        let e =
          {
            e with
            size;
            content = Slots slots;
            mtime = Unix.gettimeofday ();
            state = Owed;
          }
        in
        (* A body the durable edit names is cut only once the shorter edit is
           durable: cut first, a crash would leave the old size over it. *)
        write_edit ~durable:(!cut <> None) ~replaced:!replaced path before e;
        Option.iter
          (fun (body, len) ->
            Fs.with_fd (Staged.open_body staged body) (fun fd ->
                Fs.sys (fun () ->
                    Unix.LargeFile.ftruncate fd (Int64.of_int len))))
          !cut;
        bump path;
        mark_dirty path)

  let exists path = kind path <> `Absent

  let create path ~exclusive =
    check_writable ();
    with_key path (fun () ->
        if exclusive && exists path then
          Fail.raise_ Fail.Exists "%s exists" path;
        if Mirror.kind mirror path = `Dir then
          Fail.raise_ Fail.Exists "%s is a folder" path;
        begin_change ~durable:false path;
        let before = Staged.edit staged path in
        let e =
          {
            Staged.name = Names.leaf_of path;
            size = 0;
            mtime = Unix.gettimeofday ();
            chunk_size = R.chunk_size ();
            content = Slots [||];
            state = Owed;
          }
        in
        write_edit path before e;
        ignore (Mirror.ensure_file_id mirror path);
        bump path;
        mark_dirty path)

  let sync_edit path =
    match Staged.edit staged path with
      | None -> ()
      | Some e ->
          fsync_bodies e;
          Staged.write staged path e;
          Sync_state.harden sync_state (`File (place_of path))

  let sync path = with_key path (fun () -> sync_edit path)

  (* publication §4.1: a content change is in the feed once it is durable. *)
  let feed_put path size =
    feed
      ?fids:(Option.map (fun fid -> [(0, fid)]) (Mirror.file_id mirror path))
      [Op.Put { path; size }];
    changed [path]

  let post_put path =
    ignore
      (Dqueue.post uploads
         { file = place_of path; attempts = 0; last_error = None })

  let close path =
    with_key path (fun () ->
        let was_dirty =
          Mutex.protect dirty_m (fun () ->
              let x = Hashtbl.mem dirty path in
              Hashtbl.remove dirty path;
              x)
        in
        match Staged.edit staged path with
          | Some e when was_dirty ->
              sync_edit path;
              post_put path;
              feed_put path e.size
          | _ -> ())

  let aside_name path ~is_dir =
    let parent = Names.parent_of path in
    Names.join parent
      (Conflict.free ~client:C.client_name ~is_dir
         ~taken:(fun leaf -> kind (Names.join parent leaf) <> `Absent)
         (Names.leaf_of path))

  (* security-model §7.3: a file handed over from another filesystem is read a
     block at a time, through a descriptor that follows no link. *)
  let copy_regular ~src ~dst =
    let not_regular () =
      Fail.raise_ Fail.Invalid "%s: the handed-over file is not a regular file"
        src
    in
    let from =
      match Fs.open_nofollow src with
        | Some fd -> fd
        | None | (exception Fail.E _) | (exception Unix.Unix_error _) ->
            not_regular ()
    in
    Fs.with_fd from @@ fun from ->
    if (Unix.LargeFile.fstat from).st_kind <> S_REG then not_regular ();
    let tmp = Fs.temp_in (Filename.dirname dst) in
    match
      Fs.with_fd
        (Fs.openfile tmp [O_WRONLY; O_CREAT; O_EXCL])
        (fun into ->
          let block = Bytes.create (1 lsl 20) in
          let rec pump () =
            match
              Fs.sys (fun () -> Unix.read from block 0 (Bytes.length block))
            with
              | 0 -> ()
              | n ->
                  Fs.write_all into (Bytes.sub_string block 0 n);
                  pump ()
          in
          pump ();
          Fs.fsync into);
      Fs.rename tmp dst
    with
      | () -> ()
      | exception e ->
          Fs.unlink_quiet tmp;
          raise e

  (* 04 §4.3 [write_whole]: the handed-over file is adopted by rename, never
     copied when on the same filesystem. An edit of a version this client no
     longer holds is staged aside as a new file (conflict-resolution §4.9). *)
  let write_whole path ~src ?base ~exclusive () =
    check_writable ();
    if exclusive && exists path then Fail.raise_ Fail.Exists "%s exists" path;
    let stale =
      match base with Some b -> content_id path <> Some b | None -> false
    in
    let path = if stale then aside_name path ~is_dir:false else path in
    with_key path (fun () ->
        if Mirror.kind mirror path = `Dir then
          Fail.raise_ Fail.Exists "%s is a folder" path;
        begin_change path;
        let before = Staged.edit staged path in
        let current = content_id path in
        with_new_bodies path @@ fun register ->
        let id = Staged.new_body_id () in
        register id;
        let dst = Staged.whole_path staged id in
        Fs.mkdir_p (Filename.dirname dst);
        (match Fs.rename src dst with
          | () -> ()
          | exception Fail.E { kind = Refused; _ } ->
              copy_regular ~src ~dst;
              Fs.unlink_quiet src);
        (* The handover was checked before the rename: whatever was swapped in
           since must still be a regular file, never a link the owner follows. *)
        (match Fs.lstat_opt dst with
          | Some { st_kind = S_REG; _ } -> ()
          | _ ->
              Fs.unlink_quiet dst;
              Fail.raise_ Fail.Invalid
                "%s: the handed-over file is not a regular file" path);
        Fs.with_fd (Fs.openfile dst [O_RDONLY]) Fs.fsync;
        Fs.fsync_dir (Filename.dirname dst);
        let st = Fs.sys (fun () -> Unix.LargeFile.stat dst) in
        let size = Int64.to_int st.st_size and chunk_size = R.chunk_size () in
        let h1 = digest_of_body ~size ~cs:chunk_size id in
        if h1 <> None && h1 = current then (
          release_body id;
          settle path)
        else (
          let e =
            {
              Staged.name = Names.leaf_of path;
              size;
              mtime = st.st_mtime;
              chunk_size;
              content = Whole { body = id; h1 };
              state = Owed;
            }
          in
          Staged.write staged path e;
          (* The bodies the new edit superseded go first: a raise from the
             file id must not keep them (pitfall C-7.10). *)
          Option.iter (fun o -> release_unnamed o (Some e)) before;
          ignore (Mirror.ensure_file_id mirror path);
          bump path;
          post_put path;
          feed_put path e.size))

  (* 04 §2.8 [fids]: read before the local half, which may remove a marker. *)
  let fid_of_op op =
    let file =
      match op with
        | Op.Put { path; _ } | Delete path -> Some path
        | Rename { is_dir = false; src; _ } -> Some src
        | _ -> None
    in
    Option.bind file (Mirror.file_id mirror)

  (* The ids a feed line carries: [known] by index, else the id now at the
     path an op leaves its file at. *)
  let note_fids ?(known = []) ops =
    List.concat
      (List.mapi
         (fun i op ->
           match List.assoc_opt i known with
             | Some id -> [(i, id)]
             | None -> (
                 let at =
                   match op with
                     | Op.Put { path; _ } -> Some path
                     | Rename { is_dir = false; dst; _ } -> Some dst
                     | _ -> None
                 in
                 match Option.bind at (Mirror.file_id mirror) with
                   | Some id -> [(i, id)]
                   | None -> []))
         ops)

  (* 04 §4.5, under the metadata lock: the intent, the local half (which
     records its before-values first and drops those it returned to), the feed
     line, then the intent's removal. *)
  let namespace_op op local =
    let fid = fid_of_op op in
    let id =
      Dqueue.Records.create intents (encode_intent op (Option.to_list fid))
    in
    Fun.protect ~finally:(fun () -> Dqueue.Records.complete intents id) local;
    let known = match fid with Some f -> [(0, f)] | None -> [] in
    feed ~fids:(note_fids ~known [op]) [op];
    changed (Op.paths op);
    wake_cycle ()

  let cancel_upload path =
    Option.iter
      (fun place -> Dqueue.cancel_key uploads (upload_key place))
      (place_opt path)

  let remove_local_file l =
    cancel_upload l;
    end_lineage l;
    (match Mirror.manifest mirror l with
      | Some m -> Cache.evict cache m
      | None -> ());
    Mirror.remove_file mirror l

  let discard_edit path =
    match Staged.edit staged path with
      | Some e ->
          end_lineage path;
          Staged.remove staged path;
          release_unnamed e None;
          bump path;
          Some e
      | None -> None

  (* The local half of a delete, under the key's lock. *)
  let delete_held path =
    begin_change path;
    ignore (discard_edit path);
    cancel_upload path;
    end_lineage path;
    Mirror.remove_file mirror path;
    settle path

  let delete path =
    check_writable ();
    with_meta (fun () ->
        if Mirror.kind mirror path = `Dir then
          Fail.invalid "%s is a folder" path;
        if not (exists path) then Fail.absent "%s: no such file" path;
        ignore (require_parent path);
        namespace_op (Op.Delete path) (fun () ->
            with_key path (fun () -> delete_held path)))

  let mkdir path ~exclusive =
    check_writable ();
    with_meta (fun () ->
        match Mirror.kind mirror path with
          | `Dir -> if exclusive then Fail.raise_ Fail.Exists "%s exists" path
          | `File -> Fail.raise_ Fail.Exists "%s is a file" path
          | `Absent ->
              if Staged.edit staged path <> None then
                Fail.raise_ Fail.Exists "%s is a file" path;
              ignore (require_parent path);
              let id = Identity.mint folder_minter in
              namespace_op
                (Op.Mkdir { path; id = Some id })
                (fun () ->
                  Sync_state.record_folder sync_state id None;
                  ignore (Mirror.record_folder mirror path id)))

  let require_id path =
    match Mirror.folder_id mirror path with
      | Some id -> id
      | None ->
          Fail.raise_ Fail.Unprepared ~repair:"run 'tsync sync --full'"
            "%s: this folder has no id here" path

  (* The local half of removing an empty folder. *)
  let rmdir_held path id =
    note_folder id;
    Mirror.remove_folder mirror path;
    settle_folder id

  let rmdir path =
    check_writable ();
    with_meta (fun () ->
        if Mirror.kind mirror path <> `Dir then
          Fail.absent "%s: no such folder" path;
        ignore (require_parent path);
        if Mirror.list mirror path <> [] || Staged.edits_under staged path <> []
        then Fail.raise_ Fail.Not_empty "%s is not empty" path;
        let id = require_id path in
        namespace_op
          (Op.Rmdir { path; id = Some id })
          (fun () -> rmdir_held path id))

  (* 04 §4.5 [remove_tree]: children before parents, one command per item;
     the ops of its feed line with the ids of the files they name. *)
  let rec remove_tree_held path =
    let below =
      List.concat_map
        (fun (e : entry) ->
          let p = Names.join path e.name in
          if e.is_dir then remove_tree_held p
          else (
            let fid = Mirror.file_id mirror p in
            with_key p (fun () -> delete_held p);
            [(Op.Delete p, fid)]))
        (list_children path)
    in
    match Mirror.folder_id mirror path with
      | Some id ->
          rmdir_held path id;
          below @ [(Op.Rmdir { path; id = Some id }, None)]
      | None ->
          Mirror.remove_folder mirror path;
          below

  let remove_tree path =
    check_writable ();
    with_meta (fun () ->
        if Mirror.kind mirror path <> `Dir then
          Fail.absent "%s: no such folder" path;
        ignore (require_parent path);
        let id = require_id path in
        let intent =
          Dqueue.Records.create intents
            (encode_intent (Op.Rmdir { path; id = Some id }) [])
        in
        let ops =
          Fun.protect
            ~finally:(fun () -> Dqueue.Records.complete intents intent)
            (fun () -> remove_tree_held path)
        in
        feed
          ~fids:
            (List.concat
               (List.mapi
                  (fun i (_, fid) ->
                    match fid with Some f -> [(i, f)] | None -> [])
                  ops))
          (List.map fst ops);
        changed (List.concat_map (fun (op, _) -> Op.paths op) ops);
        wake_cycle ())

  (* Every staged edit a rename moved is posted again under its new key. *)
  let repost_moved moved =
    List.iter
      (fun (p, (e : Staged.edit)) -> if e.state = Owed then post_put p)
      moved

  (* The source key's upload is superseded: a running one fails its commit
     check, a queued one finds no edit there. *)
  let supersede src =
    bump src;
    cancel_upload src

  let move_edit ~src ~dst =
    supersede src;
    Staged.move staged ~src ~dst

  let rename_local ~src ~dst ~is_dir =
    if is_dir then (
      let moved = Staged.edits_under staged src in
      List.iter (fun (p, _) -> supersede p) moved;
      Mirror.move_folder mirror ~src ~dst;
      let sdir = Staged.manifest_path staged src
      and ddir = Staged.manifest_path staged dst in
      if Fs.exists sdir then (
        Fs.mkdir_p (Filename.dirname ddir);
        Fs.rename sdir ddir;
        Fs.fsync_dir (Filename.dirname ddir));
      move_handles ~src ~dst;
      List.map
        (fun (p, e) ->
          ( dst
            ^ String.sub p (String.length src)
                (String.length p - String.length src),
            e ))
        moved)
    else (
      let e = Staged.edit staged src in
      move_edit ~src ~dst;
      Mirror.move_file mirror ~src ~dst;
      move_handles ~src ~dst;
      match e with Some e -> [(dst, e)] | None -> [])

  (* A file moved with everything that follows it, both keys settled; under
     the two key locks. *)
  let move_file_held ~src ~dst =
    begin_change src;
    begin_change dst;
    let moved = rename_local ~src ~dst ~is_dir:false in
    settle src;
    settle dst;
    repost_moved moved

  (* Completing an intent (04 §4.5): idempotent. *)
  let redo = function
    | Op.Delete p -> if kind p = `File then with_key p (fun () -> delete_held p)
    | Mkdir { path; id = Some id } ->
        if
          Mirror.key_of_id mirror id = None && Mirror.kind mirror path = `Absent
        then (
          Sync_state.record_folder sync_state id None;
          ignore (Mirror.record_folder mirror path id))
    | Rmdir { id = Some id; _ } -> (
        match Mirror.key_of_id mirror id with
          | Some p -> ignore (remove_tree_held p)
          | None -> ())
    | Rename { is_dir = false; src; dst; _ } ->
        if kind src <> `Absent && kind dst = `Absent then
          with_keys [src; dst] (fun () -> move_file_held ~src ~dst)
    | Rename { is_dir = true; dst; id = Some id; _ } -> (
        match Mirror.key_of_id mirror id with
          | Some here when kind dst = `Absent && here <> dst ->
              note_folder id;
              repost_moved (rename_local ~src:here ~dst ~is_dir:true);
              settle_folder id
          | _ -> settle_folder id)
    | Put _
    | Mkdir { id = None; _ }
    | Rmdir { id = None; _ }
    | Rename { is_dir = true; id = None; _ } ->
        ()

  let rename ~src ~dst ~exclusive =
    check_writable ();
    if src = dst then ()
    else (
      if Names.is_under ~dir:src dst then
        Fail.invalid "cannot move %s into itself" src;
      with_meta (fun () ->
          let sk = kind src and dk = kind dst in
          if sk = `Absent then Fail.absent "%s: no such file or folder" src;
          if exclusive && dk <> `Absent then
            Fail.raise_ Fail.Exists "%s exists" dst;
          (match (sk, dk) with
            | `Dir, `Dir ->
                if
                  Mirror.list mirror dst <> []
                  || Staged.edits_under staged dst <> []
                then Fail.raise_ Fail.Not_empty "%s is not empty" dst
            | `File, `Dir -> Fail.raise_ Fail.Exists "%s is a folder" dst
            | `Dir, `File -> Fail.raise_ Fail.Exists "%s is a file" dst
            | _ -> ());
          ignore (require_parent dst);
          let is_dir = sk = `Dir in
          if is_dir then (
            ignore (require_parent src);
            let id = require_id src in
            let replaced = if dk = `Dir then Some (require_id dst) else None in
            let locked =
              [src; dst] @ List.map fst (Staged.edits_under staged src)
            in
            namespace_op
              (Op.Rename { dst; src; is_dir; size = None; id = Some id })
              (fun () ->
                with_keys locked (fun () ->
                    Option.iter (rmdir_held dst) replaced;
                    note_folder id;
                    repost_moved (rename_local ~src ~dst ~is_dir:true);
                    settle_folder id)))
          else
            namespace_op
              (Op.Rename
                 { dst; src; is_dir; size = Some (size_of src); id = None })
              (fun () ->
                with_keys [src; dst] (fun () ->
                    if dk = `File then delete_held dst;
                    move_file_held ~src ~dst))))

  (* A manifest whose chunks the main holds becomes the key's local value, as
     one local operation (publication §4.12); under the metadata lock. *)
  let install path (m : Manifest.t) =
    let m = Manifest.rename m (Names.leaf_of path) in
    with_key path (fun () ->
        begin_change path;
        ignore (discard_edit path);
        bump path;
        end_lineage path;
        Mirror.write_file ~own:true mirror path m;
        ignore (Mirror.ensure_file_id mirror path);
        settle path);
    let op = Op.Put { path; size = m.size } in
    feed ~fids:(note_fids [op]) [op];
    changed [path];
    wake_cycle ()

  let symlink path ~target ~exclusive =
    check_writable ();
    if C.symlinks <> `Keep then
      Fail.raise_ Fail.Refused "symbolic links are not kept in this domain";
    with_meta (fun () ->
        if exclusive && exists path then
          Fail.raise_ Fail.Exists "%s exists" path;
        install path
          (Manifest.symlink ~name:(Names.leaf_of path)
             ~mtime:(Unix.gettimeofday ()) target))

  let evict path =
    match Mirror.manifest mirror path with
      | Some m -> Cache.evict cache m
      | None -> ()

  (* 08 §3.3 status [downloading]: the transfers of file bytes running now. *)
  type download = { size : int; started : float; done_ : int Atomic.t }

  let downloads_m = Mutex.create ()
  let running_downloads : (int, string * download) Hashtbl.t = Hashtbl.create 8
  let download_ids = Atomic.make 0

  let downloading path ~size f =
    let id = Atomic.fetch_and_add download_ids 1 in
    let d = { size; started = Unix.gettimeofday (); done_ = Atomic.make 0 } in
    Mutex.protect downloads_m (fun () ->
        Hashtbl.replace running_downloads id (path, d));
    Fun.protect
      ~finally:(fun () ->
        Mutex.protect downloads_m (fun () ->
            Hashtbl.remove running_downloads id))
      (fun () -> f (fun n -> ignore (Atomic.fetch_and_add d.done_ n)))

  let downloads () =
    Mutex.protect downloads_m (fun () ->
        Hashtbl.fold
          (fun _ (path, d) acc ->
            {
              path;
              size = d.size;
              bytes = Atomic.get d.done_;
              started = d.started;
            }
            :: acc)
          running_downloads [])

  let pin path ~keep =
    let pin_manifest (m : Manifest.t) =
      downloading path ~size:m.size (fun fetched ->
          Cache.pin ~fetched cache m ~until:(Unix.gettimeofday () +. keep))
    in
    match resolve path with
      | Some (Published m) -> pin_manifest m
      | Some (Staged_edit _) -> (
          match base_of path with Some m -> pin_manifest m | None -> ())
      | None -> Fail.absent "%s: no such file" path

  let unpin path =
    match Mirror.manifest mirror path with
      | Some m -> Cache.unpin cache m
      | None -> ()

  let availability path =
    match resolve path with
      | Some (Staged_edit _) -> `Cached
      | Some (Published m) -> Cache.availability cache m
      | None -> `Online_only

  (* 04 §3.4: the destination is created exclusively, without following links,
     mode 0600. *)
  let create_dest dst =
    match
      Fs.eintr (fun () ->
          Unix.openfile dst [O_WRONLY; O_CREAT; O_EXCL; O_CLOEXEC] 0o600)
    with
      | fd -> fd
      | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
          Fail.raise_ Fail.Exists "%s exists" dst
      | exception Unix.Unix_error (e, fn, a) ->
          raise (Fail.E (Fail.of_unix e fn a))

  let assemble_to path dst =
    let h = open_read path in
    Fun.protect
      ~finally:(fun () -> close_read h)
      (fun () ->
        let size = size_of path in
        (* Lesson 8: the destination is closed whatever happens once it is
           open. *)
        Fs.with_fd (create_dest dst) (fun fd ->
            downloading path ~size (fun fetched ->
                let step = 4 * 1024 * 1024 in
                let rec go off =
                  if off < size then (
                    let s = read h ~off ~len:(min step (size - off)) in
                    let n = Bigstring.length s in
                    if n = 0 then Fail.corrupt "%s: short read at %d" path off;
                    Fs.pwrite_all fd s ~boff:0 ~len:n ~off;
                    fetched n;
                    go (off + n))
                in
                go 0;
                Fs.fsync fd));
        let st = stat path in
        try Unix.utimes dst st.mtime st.mtime with _ -> ())

  let fetch_range path dst ~off ~len =
    let h = open_read path in
    Fun.protect
      ~finally:(fun () -> close_read h)
      (fun () ->
        let s =
          downloading path ~size:len (fun fetched ->
              let s = read h ~off ~len in
              fetched (Bigstring.length s);
              s)
        in
        let fd = create_dest dst in
        Fs.with_fd fd (fun fd ->
            if Bigstring.length s > 0 then
              Fs.pwrite_all fd s ~boff:0 ~len:(Bigstring.length s) ~off;
            Fs.fsync fd);
        Bigstring.length s)
end
