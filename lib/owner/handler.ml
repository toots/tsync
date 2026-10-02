open Tsync_core
open Tsync_ipc
open Tsync_sync

type hooks = {
  changed : string list -> unit;
  surface_evicted : string -> unit;
  surface_restored : string -> unit;
  reannounce : unit -> unit;
  frontend : unit -> Tsync_status.Status_report.frontend option;
}

let no_hooks =
  {
    changed = ignore;
    surface_evicted = ignore;
    surface_restored = ignore;
    reannounce = ignore;
    frontend = (fun () -> None);
  }

type running = { id : int; kind : string; cancelled : bool Atomic.t }

type t = {
  domain : Tsync_domain.Domain.t;
  engine : (module Engine.S);
  hooks : hooks;
  publish : Ipc.json -> int;
  stats : string list -> Tsync_status.Status_report.answer;
  stop : unit -> unit;
  dest_roots : string list;
  staging_roots : string list;
  answered_unreachable : bool Atomic.t;
  running : running option Atomic.t;
}

let default_pin_keep = 10. *. 86400.
let page_limit = 1000
let feed_limit = 512
let event_ids = Atomic.make 0
let job_ids = Atomic.make 0

let create ~domain ~engine ~hooks ~publish ~stats ~stop ~dest_roots
    ~staging_roots =
  {
    domain;
    engine;
    hooks;
    publish;
    stats;
    stop;
    dest_roots;
    staging_roots;
    answered_unreachable = Atomic.make false;
    running = Atomic.make None;
  }

let domain_name t = Domain_name.to_string t.domain.name

let event t name fields =
  `Assoc
    ([
       ("event", `String name);
       ("domain", `String (domain_name t));
       ("id", `Int (Atomic.fetch_and_add event_ids 1 + 1));
     ]
    @ fields)

let invalid fmt = Fail.invalid fmt

(* 08 §2.3: [None] when the row's container has no id on this client. *)
let row (module E : Engine.S) ~root_name ~read_only path : Protocol.row option =
  let st = E.stat path in
  let id_of p = Option.map Folder_id.to_string (E.folder_id p) in
  let dir_ref id = Names.ref_to_string (Names.dir_ref id) in
  let parent_ref =
    if path = "" then Some "root"
    else Option.map dir_ref (id_of (Names.parent_of path))
  in
  let ref_ =
    if path = "" then Some "root"
    else (
      match st.kind with
        | `Dir ->
            Option.map dir_ref (Option.map Folder_id.to_string st.folder_id)
        | `File | `Symlink ->
            Option.map
              (fun id -> Names.ref_to_string (Names.File_id id))
              (Tsync_checkout.Mirror.file_id E.mirror path))
  in
  match (ref_, parent_ref) with
    | Some ref_, Some parent_ref ->
        let name = if path = "" then root_name else Names.leaf_of path in
        let file kind =
          {
            Protocol.ref_;
            parent_ref;
            name;
            kind;
            size = st.size;
            mtime = st.mtime;
            etag = st.etag;
            is_uploaded = not st.staged;
            content_id = None;
            symlink_target = None;
            read_only;
            availability = None;
          }
        in
        Some
          (match st.kind with
            | `Dir ->
                {
                  (file `Dir) with
                  size = 0;
                  mtime = 0.;
                  is_uploaded = true;
                  etag =
                    (match st.folder_id with
                      | Some id when path <> "" -> Folder_id.to_string id
                      | _ -> ".tsync-root");
                }
            | `Symlink -> { (file `Symlink) with symlink_target = st.target }
            | `File ->
                {
                  (file `File) with
                  content_id = st.content_id;
                  availability =
                    Some
                      (match E.availability path with
                        | `Online_only -> Online_only
                        | `Cached -> Cached
                        | `Pinned until -> Pinned until);
                })
    | _ -> None

let row_of t path =
  row t.engine ~root_name:(domain_name t) ~read_only:t.domain.domain.read_only
    path

let row_or_unnamed t path =
  match row_of t path with
    | Some r -> r
    | None ->
        Fail.raise_ Fail.Unprepared "%s cannot be named on this client" path

(* 08 §2.2: resolution mints nothing, and an f: reference never answers for a
   folder. *)
let resolve_ref (module E : Engine.S) s =
  match Names.parse_ref s with
    | Error () -> invalid "malformed item reference %S" s
    | Ok Root -> ""
    | Ok (Dir id) -> (
        match Option.bind (Folder_id.of_string id) E.path_of_id with
          | Some p -> p
          | None -> Fail.absent "%s: no such folder" s)
    | Ok (File_id id) -> (
        match Tsync_checkout.Mirror.path_of_file_id E.mirror id with
          | Some p when E.kind p = `File -> p
          | _ -> Fail.absent "%s: no such file" s)
    | Ok (File (id, leaf)) -> (
        match Option.bind (Folder_id.of_string id) E.path_of_id with
          | Some parent ->
              let p = Names.join parent leaf in
              if E.kind p = `File then p else Fail.absent "%s: no such file" s
          | None -> Fail.absent "%s: no such file" s)

let resolve_rel (module E : Engine.S) rel =
  let parts = String.split_on_char '/' rel in
  if rel <> "" && List.exists (fun c -> c = "" || c = "." || c = "..") parts
  then invalid "malformed relative path %S" rel;
  if E.kind rel = `Absent then Fail.absent "%s: not found" rel;
  rel

(* 08 §3.5: a destination is a parent folder and a valid leaf. *)
let destination t (d : Protocol.destination) =
  let (module E : Engine.S) = t.engine in
  let parent = resolve_ref t.engine d.parent_ref in
  if E.kind parent <> `Dir then invalid "parentRef does not name a folder";
  if not (Names.valid_leaf d.name) then invalid "invalid name %S" d.name;
  Names.join parent d.name

let target t : Protocol.target -> string = function
  | Ref r -> resolve_ref t.engine r
  | Rel rel -> resolve_rel t.engine rel
  | Child d ->
      let (module E : Engine.S) = t.engine in
      let path = destination t d in
      if E.kind path = `Absent then Fail.absent "%s: not found" d.name;
      path

(* 08 §3.3: [exists] carries the occupant's row when it can be named. *)
exception Occupied of Fail.t * Protocol.row

let occupied t path f =
  try f ()
  with Fail.E ({ kind = Exists; _ } as fail) as e -> (
    match row_of t path with
      | Some r -> raise (Occupied (fail, r))
      | None | (exception _) -> raise e)

(* 08 §3.5: the reply's row describes exactly the bytes written. The content
   is read again after the transfer; a change in between is served again. *)
let transfer_attempts = 3

let serving t path dest f =
  let identity (r : Protocol.row) = (r.content_id, r.etag, r.size, r.mtime) in
  let rec go n =
    let before = row_or_unnamed t path in
    let result = f () in
    let after = row_or_unnamed t path in
    if identity before = identity after then (result, after)
    else (
      Fs.unlink_quiet dest;
      if n <= 1 then
        Fail.raise_ Fail.Load "%s changed while it was being served" path;
      go (n - 1))
  in
  go transfer_attempts

(* 08 §3.4: per-file failures are counted and do not stop the walk. *)
let each_file t path f =
  let (module E : Engine.S) = t.engine in
  let files =
    if E.kind path = `Dir then
      E.atomically (fun () ->
          List.filter_map
            (fun (p, (st : Local_ops.stat)) ->
              if st.kind = `File then Some p else None)
            (E.list_tree path))
    else [path]
  in
  let ok = ref 0 and failed = ref 0 and last = ref None in
  List.iter
    (fun p ->
      match f p with
        | () -> incr ok
        | exception e when not (Rt.is_cancelled e) ->
            incr failed;
            last := Some (Fail.classify e);
            Log.info "%s: %s" p (Printexc.to_string e))
    files;
  (match !last with
    | Some f when !ok = 0 && f.kind = Unreachable -> raise (Fail.E f)
    | _ -> ());
  (!ok, !failed)

let rmdir_subtree (module E : Engine.S) path =
  let entries = E.list_tree path in
  List.iter
    (fun (p, (st : Local_ops.stat)) -> if st.kind <> `Dir then E.delete p)
    entries;
  List.iter
    (fun (p, (st : Local_ops.stat)) -> if st.kind = `Dir then E.rmdir p)
    (List.rev entries);
  E.rmdir path

let list_dir t dir ~after ~limit : Protocol.page =
  let (module E : Engine.S) = t.engine in
  let path = target t dir in
  if E.kind path <> `Dir then invalid "not a folder";
  let after = Option.value ~default:"" after in
  let limit = Option.value ~default:page_limit limit in
  if limit < 1 then invalid "limit must be positive";
  let names =
    List.filter
      (fun (e : E.entry) -> String.compare e.name after > 0)
      (E.list_children path)
  in
  let rec take n acc = function
    | x :: rest when n > 0 -> take (n - 1) (x :: acc) rest
    | rest -> (List.rev acc, rest <> [])
  in
  let page, more = take limit [] names in
  let rows =
    List.map (fun (e : E.entry) -> row_of t (Names.join path e.name)) page
  in
  {
    items = List.filter_map Fun.id rows;
    next =
      (match (more, List.rev page) with
        | true, (last : E.entry) :: _ -> Some last.name
        | _ -> None);
    unnamed = List.length (List.filter Option.is_none rows);
  }

(* 08 §3.6 step 6: names come from the folder-id index, which keeps an id after
   its marker went, and from the file id the applied log recorded, so an op
   names its item even after it moved or went; [None] counts as unnamed. *)
let feed_op t (o : Applied.op) : Protocol.feed_op option =
  let (module E : Engine.S) = t.engine in
  let module M = Tsync_checkout.Mirror in
  let dir_ref id =
    Names.ref_to_string (Names.dir_ref (Folder_id.to_string id))
  in
  let parent_ref path =
    Option.map dir_ref (M.lookup_id_removed E.mirror (Names.parent_of path))
  in
  let file_ref path =
    match o.fid with Some id -> Some id | None -> M.file_id E.mirror path
  in
  let file_item fid = Option.bind (M.path_of_file_id E.mirror fid) (row_of t) in
  let dir_item id = Option.bind (M.key_of_id E.mirror id) (row_of t) in
  let folder_id path given =
    match given with
      | Some id -> Some id
      | None -> M.lookup_id_removed E.mirror path
  in
  let leaf = Names.leaf_of in
  let ( let* ) = Option.bind in
  match o.op with
    | Put { path; _ } ->
        let* fid = file_ref path in
        let* parent_ref = parent_ref path in
        Some
          (Protocol.Put_op
             {
               ref_ = Names.ref_to_string (File_id fid);
               parent_ref;
               name = leaf path;
               item = file_item fid;
             })
    | Delete path ->
        let* fid = file_ref path in
        let* parent_ref = parent_ref path in
        Some
          (Protocol.Delete_op
             {
               ref_ = Names.ref_to_string (File_id fid);
               parent_ref;
               name = leaf path;
             })
    | Mkdir { path; id } ->
        let* id = folder_id path id in
        let* parent_ref = parent_ref path in
        Some
          (Protocol.Mkdir_op
             {
               ref_ = dir_ref id;
               parent_ref;
               name = leaf path;
               item = dir_item id;
             })
    | Rmdir { path; id } ->
        let* id = folder_id path id in
        let* parent_ref = parent_ref path in
        Some
          (Protocol.Rmdir_op
             {
               id = Folder_id.to_string id;
               ref_ = dir_ref id;
               parent_ref;
               name = leaf path;
             })
    | Rename { src; dst; is_dir; id; _ } ->
        let* ref_, id, item =
          if is_dir then
            let* id = folder_id dst id in
            Some (dir_ref id, Some (Folder_id.to_string id), dir_item id)
          else
            let* fid = file_ref dst in
            Some (Names.ref_to_string (File_id fid), None, file_item fid)
        in
        let* src_parent_ref = parent_ref src in
        let* parent_ref = parent_ref dst in
        Some
          (Protocol.Rename_op
             {
               is_dir;
               id;
               src_ref = ref_;
               src_parent_ref;
               ref_;
               parent_ref;
               name = leaf dst;
               item;
             })

let changes t ~anchor ~limit : Protocol.changes =
  let (module E : Engine.S) = t.engine in
  let limit = Option.value ~default:feed_limit limit in
  if limit < 1 then invalid "limit must be positive";
  match E.changes_since anchor ~limit with
    | `Stale -> Stale
    | `Page (cursor, more, ops) ->
        let rendered = List.map (feed_op t) ops in
        Changes
          {
            cursor;
            more;
            ops = List.filter_map Fun.id rendered;
            unnamed = List.length (List.filter Option.is_none rendered);
          }

(* 08 §3.7: the first page walks the mirror, sorts by path and keeps the walk;
   later pages read the kept file from the cursor's offset. An entry whose path
   no longer resolves is skipped: the feed reports its change. *)
let walk_file t =
  let (module E : Engine.S) = t.engine in
  Filename.concat
    (Filename.concat (Tsync_checkout.Mirror.root E.mirror) "scratch")
    ".tsync-walk"

let walk_domain t =
  let (module E : Engine.S) = t.engine in
  let skipped = ref 0 in
  let rec walk dir container acc =
    List.fold_left
      (fun acc (e : E.entry) ->
        let path = Names.join dir e.name in
        if e.is_dir then (
          match E.folder_id path with
            | None ->
                incr skipped;
                acc
            | Some id ->
                walk path (Folder_id.to_string id)
                  ({
                     Kept_walk.path;
                     container;
                     kind = `Dir;
                     size = 0;
                     mtime = 0.;
                   }
                  :: acc))
        else
          {
            Kept_walk.path;
            container;
            kind = `File;
            size = e.st.size;
            mtime = e.st.mtime;
          }
          :: acc)
      acc (E.list_children dir)
  in
  let entries = walk "" (Folder_id.to_string Folder_id.root) [] in
  ( List.sort
      (fun (a : Kept_walk.entry) b -> String.compare a.path b.path)
      entries,
    !skipped )

let list_all t ~after ~limit : Protocol.listing =
  let limit = Option.value ~default:page_limit limit in
  if limit < 1 then invalid "limit must be positive";
  let file = walk_file t in
  let cursor, unnamed =
    match after with
      | Some c -> (Some c, 0)
      | None -> (
          let entries, skipped = walk_domain t in
          match Kept_walk.write file ~skipped entries with
            | _ -> (Kept_walk.first_cursor file, skipped)
            | exception e ->
                Log.warn "%s: the kept walk could not be written: %s"
                  (domain_name t) (Printexc.to_string e);
                (None, skipped))
  in
  match cursor with
    | None -> Walk_stale
    | Some cursor -> (
        match Kept_walk.page file ~cursor ~limit with
          | `Stale -> Walk_stale
          | `Page (paths, next) ->
              let rows =
                List.map (fun p -> try row_of t p with _ -> None) paths
              in
              Listed { items = List.filter_map Fun.id rows; next; unnamed })

let event_json t ev = event t (Protocol.event_name ev) []
let publish_event t ev = t.publish (event_json t ev)

let print_line = function
  | Protocol.Started _ -> ()
  | Out s -> Display.out s
  | Narration s -> (Display.narrate ()).say s
  | Progress { text = ""; _ } -> Display.clear ()
  | Progress { text; fraction } -> (Display.narrate ()).progress ?fraction text

(* A job reports every unit; over a socket a few a second are enough, and the
   latest held back goes before any other line, so what is shown is current. *)
let progress_every = 0.25

let throttled send =
  let last = ref 0. and held = ref None in
  fun (l : Protocol.line) ->
    match l with
      | Progress { text; _ } when text <> "" ->
          let now = Unix.gettimeofday () in
          if now -. !last >= progress_every then (
            last := now;
            held := None;
            send l)
          else held := Some l
      | _ ->
          Option.iter send !held;
          held := None;
          send l

(* 07 §4.6 JOB_REPORT_INTERVAL. *)
let job_report_interval = 10.

(* A job's fraction as the report's counts, and an ETA from its own rate; none
   before anything moved or once it is done. *)
let job_progress ~started = function
  | Some f when f > 0. && f < 1. ->
      let finished = int_of_float (f *. 100.) in
      Some
        {
          Tsync_status.Status_report.total = 100;
          skipped = 0;
          finished;
          handled = finished;
          remaining = 100 - finished;
          eta = Some ((Rt.now () -. started) *. (1. -. f) /. f);
        }
  | _ -> None

(* 07 §4.6: a missing supervisor is the ordinary case, and reporting never
   decides whether a job runs. *)
let send_report t ~kind ~state ~error ~progress ~step =
  match
    Tsync_status.Status_report.job_to_yojson
      {
        pid = Unix.getpid ();
        kind;
        domain = Some (domain_name t);
        state;
        error;
        progress;
        step;
      }
  with
    | `Assoc fields ->
        Ipc.advisory
          (Tsync_config.Paths.supervisor_socket ())
          (`Assoc (("action", `String "report") :: fields))
    | _ -> ()

(* 07 §2.5. ponytail: one job per domain at a time, so jobs that would not
   conflict wait too; a conflict table if that ever matters. *)
let run_job t ~send ~narrate job =
  let me =
    {
      id = Atomic.fetch_and_add job_ids 1 + 1;
      kind = Jobs.kind job;
      cancelled = Atomic.make false;
    }
  in
  if not (Atomic.compare_and_set t.running None (Some me)) then
    Fail.raise_ Fail.Load "busy: %s is running on %s"
      (match Atomic.get t.running with
        | Some j -> Printf.sprintf "tsync %s (job %d)" j.kind j.id
        | None -> "another job")
      (domain_name t);
  let latest = Atomic.make ("", None) and started = Rt.now () in
  let report state ?error () =
    let text, fraction = Atomic.get latest in
    send_report t ~kind:me.kind ~state ~error
      ~progress:(job_progress ~started fraction)
      ~step:(if text = "" || state <> `Running then None else Some text)
  in
  let finished = Atomic.make false in
  report `Running ();
  Rt.spawn ~name:"job report" (fun () ->
      let rec loop () =
        Rt.sleep job_report_interval;
        if not (Atomic.get finished) then (
          report `Running ();
          loop ())
      in
      loop ());
  let outcome =
    Fun.protect
      ~finally:(fun () ->
        Atomic.set finished true;
        send (Protocol.Progress { text = ""; fraction = None });
        Atomic.set t.running None;
        Usage.release ())
      (fun () ->
        send (Protocol.Started me.id);
        match
          Jobs.run
            {
              out = (fun s -> send (Out s));
              narrate =
                {
                  say =
                    (if narrate then fun s -> send (Narration s) else ignore);
                  progress =
                    (fun ?fraction text ->
                      Atomic.set latest (text, fraction);
                      send (Progress { text; fraction }));
                };
              cancelled =
                (fun () -> Atomic.get me.cancelled || Stop.requested ());
            }
            t.domain t.engine job
        with
          | code -> Ok code
          | exception e -> Error e)
  in
  match outcome with
    | Ok code ->
        report
          (if code = 0 then `Done else `Failed)
          ?error:(if code = 0 then None else Some "finished with failures")
          ();
        code
    | Error e ->
        report `Failed ~error:(Fail.classify e).reason ();
        raise e

let cancel t id =
  match Atomic.get t.running with
    | Some j when j.id = id ->
        Atomic.set j.cancelled true;
        true
    | _ -> false

(* 08 §3.3, one request; [ref] names the surface to update after evict and
   restore. *)
let act : type a. t -> send:(Protocol.line -> unit) -> a Protocol.request -> a =
 fun t ~send req ->
  let (module E : Engine.S) = t.engine in
  let mutate f = E.atomically f in
  let surface = function Protocol.Ref r -> r | Rel _ | Child _ -> "root" in
  match req with
    | Ping -> ()
    | Stat item -> row_or_unnamed t (target t item)
    | List_dir r -> list_dir t r.dir ~after:r.after ~limit:r.limit
    | List_all r -> list_all t ~after:r.after ~limit:r.limit
    | Status ->
        {
          Protocol.domain = domain_name t;
          read_only = t.domain.domain.read_only;
          paused = E.is_paused ();
          pending_uploads = E.pending_uploads ();
          mount = Option.bind (t.hooks.frontend ()) (fun f -> f.mount);
        }
    | Stats args -> t.stats args
    | Stop -> t.stop ()
    | Poll -> Rt.spawn ~name:"poll" E.poll
    | Pause on ->
        E.set_paused on;
        E.is_paused ()
    | Retry -> E.rearm ()
    | Trash_restore path -> (
        match E.restore_from_trash path with
          | `Restored n -> Protocol.Restored n
          | `Not_in_trash -> Not_in_trash
          | `Exists -> Name_taken)
    | Share r ->
        let module S =
          Tsync_gc.Share.Make ((val Tsync_domain.Domain.context t.domain)) in
        let c = S.create ?expires:r.expires ?token:r.token r.rel in
        { Protocol.url = c.url; expires = c.expires }
    | Share_revoke s ->
        let module S =
          Tsync_gc.Share.Make ((val Tsync_domain.Domain.context t.domain)) in
        S.revoke s
    | Share_clear_cache ->
        let module S =
          Tsync_gc.Share.Make ((val Tsync_domain.Domain.context t.domain)) in
        S.clear_cache ()
    | Job r -> run_job t ~send ~narrate:r.narrate r.job
    | Cancel id -> cancel t id
    | Notify_reset -> publish_event t Reset
    | Full_resync ->
        E.stamp_generation ();
        t.hooks.reannounce ()
    | Cursor -> E.cursor ()
    | Changes_since r -> changes t ~anchor:r.anchor ~limit:r.limit
    | Sync r -> (
        match E.resync ~full:r.full () with
          | `Incremental n -> Protocol.Incremental n
          | `Full (manifests, failed) -> Protocol.Full { manifests; failed })
    | Ensure_cached r ->
        let path = target t r.item in
        Transfer.check_dest ~roots:t.dest_roots r.dest;
        let (), item =
          serving t path r.dest (fun () -> E.assemble_to path r.dest)
        in
        { Protocol.local_path = r.dest; item }
    | Fetch_range r ->
        let path = target t r.item in
        if r.offset < 0 || r.length <= 0 then
          invalid "offset ≥ 0 and length > 0 are required";
        Transfer.check_dest ~roots:t.dest_roots r.dest;
        let length, item =
          serving t path r.dest (fun () ->
              E.fetch_range path r.dest ~off:r.offset ~len:r.length)
        in
        { Protocol.local_path = r.dest; offset = r.offset; length; item }
    | Download_progress _ -> Protocol.Inactive
    | Evict item ->
        let succeeded, failed = each_file t (target t item) E.evict in
        t.hooks.surface_evicted (surface item);
        { Protocol.succeeded; failed }
    | Restore r ->
        let keep = Option.value ~default:default_pin_keep r.keep in
        let succeeded, failed =
          each_file t (target t r.item) (fun p -> E.pin p ~keep)
        in
        t.hooks.surface_restored (surface r.item);
        { Protocol.succeeded; failed }
    | Create r ->
        mutate (fun () ->
            let path = destination t r.at in
            occupied t path (fun () -> E.create path ~exclusive:r.exclusive);
            E.close path;
            row_or_unnamed t path)
    | Write r ->
        Transfer.check_staging ~roots:t.staging_roots r.staging;
        mutate (fun () ->
            let path =
              match r.at with
                | Child d -> destination t d
                | at ->
                    let p = target t at in
                    if E.kind p <> `File then invalid "write names a file";
                    p
            in
            occupied t path (fun () ->
                E.write_whole path ~src:r.staging ?base:r.base
                  ~exclusive:r.exclusive ());
            let item = row_or_unnamed t path in
            { Protocol.size = item.size; mtime = item.mtime; item })
    | Mkdir r ->
        mutate (fun () ->
            let path = destination t r.at in
            if r.exclusive || E.kind path <> `Dir then
              occupied t path (fun () -> E.mkdir path ~exclusive:r.exclusive);
            row_or_unnamed t path)
    | Symlink r ->
        mutate (fun () ->
            let path = destination t r.at in
            occupied t path (fun () ->
                E.symlink path ~target:r.link_target ~exclusive:r.exclusive);
            row_or_unnamed t path)
    | Rename r ->
        mutate (fun () ->
            let src = resolve_ref t.engine r.src in
            let dst = destination t r.at in
            if src <> dst then
              occupied t dst (fun () ->
                  (match (E.kind src, E.kind dst) with
                    | _, `Absent -> ()
                    | `File, `File when not r.noreplace -> ()
                    | _ -> Fail.raise_ Fail.Exists "%s exists" dst);
                  E.rename ~src ~dst ~exclusive:r.noreplace);
            row_or_unnamed t dst)
    | Delete item ->
        mutate (fun () ->
            let path = target t item in
            if E.kind path = `Dir then invalid "a folder is removed with rmdir";
            E.delete path)
    | Rmdir item ->
        mutate (fun () ->
            let path = target t item in
            if path = "" then invalid "the root cannot be removed";
            if E.kind path <> `Dir then invalid "not a folder";
            rmdir_subtree t.engine path)

(* failure-model §8.2: the reply is bounded, the work behind it is not. *)
let bounded f =
  let p = Rt.Promise.create () in
  Rt.spawn ~name:"request" (fun () ->
      ignore
        (Rt.Promise.try_resolve_result p (try Ok (f ()) with e -> Error e)));
  try Rt.with_timeout Ipc.request_deadline (fun () -> Rt.Promise.await p)
  with Rt.Timeout -> Fail.raise_ Fail.Deadline "still in progress; retry"

(* 08 §3.5: the rules every request meets before it acts. *)
let call_with : type a.
    t -> send:(Protocol.line -> unit) -> a Protocol.request -> a =
 fun t ~send req ->
  let (module E : Engine.S) = t.engine in
  if Protocol.mutates req && t.domain.domain.read_only then
    Fail.raise_ Fail.Read_only "%s is read-only" (domain_name t);
  if Protocol.refused_while_paused req && E.is_paused () then
    Fail.raise_ Fail.Paused "%s is paused" (domain_name t);
  match req with
    | Ping | Stop -> act t ~send req
    | _ when Protocol.bulk req -> act t ~send req
    | _ -> bounded (fun () -> act t ~send req)

let call t req =
  try call_with t ~send:print_line req
  with Occupied (f, _) -> raise (Fail.E f)

(* 08 §3.8: a bulk success after an [unreachable] answer tells subscribers
   the domain recovered. *)
let note_reachability t ~bulk reply =
  match Ipc.field reply "code" with
    | Some "unreachable" -> Atomic.set t.answered_unreachable true
    | Some _ -> ()
    | None ->
        if bulk && Atomic.exchange t.answered_unreachable false then
          ignore (publish_event t Recovered)

let answer t json =
  match Ipc.field json "action" with
    | Some "subscribe" ->
        Ipc.Subscribe (domain_name t, Ipc.ok [], [event t "recovered" []])
    | _ -> (
        match Protocol.decode json with
          | Request (Job _ as req) ->
              Ipc.Stream
                (fun send ->
                  match
                    call_with t
                      ~send:
                        (throttled (fun l -> send (Protocol.line_to_json l)))
                      req
                  with
                    | r -> Protocol.encode_reply req r
                    | exception e -> Ipc.failure (Fail.classify e))
          | Request req ->
              let reply =
                match call_with t ~send:print_line req with
                  | r -> Protocol.encode_reply req r
                  | exception Occupied (f, r) -> (
                      match Ipc.failure f with
                        | `Assoc l -> `Assoc (l @ Protocol.item r)
                        | j -> j)
                  | exception e -> Ipc.failure (Fail.classify e)
              in
              note_reachability t ~bulk:(Protocol.bulk req) reply;
              Ipc.Reply reply
          | exception e -> Ipc.Reply (Ipc.failure (Fail.classify e)))
