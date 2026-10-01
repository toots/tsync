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
  dest_roots : string list Atomic.t;
  staging_roots : string list;
  answered_unreachable : bool Atomic.t;
  running : running option Atomic.t;
}

let default_pin_keep = 10. *. 86400.
let page_limit = 1000
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
    dest_roots = Atomic.make dest_roots;
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
let row (module E : Engine.S) ~root_name path : Protocol.row option =
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
              (fun id ->
                Names.ref_to_string (Names.File (id, Names.leaf_of path)))
              (id_of (Names.parent_of path)))
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

let row_or_unnamed t path =
  match row t.engine ~root_name:(domain_name t) path with
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

let target t : Protocol.target -> string = function
  | Ref r -> resolve_ref t.engine r
  | Rel rel -> resolve_rel t.engine rel

(* 08 §3.5: a destination is a parent folder and a valid leaf. *)
let destination t (d : Protocol.destination) =
  let (module E : Engine.S) = t.engine in
  let parent = resolve_ref t.engine d.parent_ref in
  if E.kind parent <> `Dir then invalid "parentRef does not name a folder";
  if not (Names.valid_leaf d.name) then invalid "invalid name %S" d.name;
  Names.join parent d.name

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
    List.map
      (fun (e : E.entry) ->
        row t.engine ~root_name:(domain_name t) (Names.join path e.name))
      page
  in
  {
    items = List.filter_map Fun.id rows;
    next =
      (match (more, List.rev page) with
        | true, (last : E.entry) :: _ -> Some last.name
        | _ -> None);
    unnamed = List.length (List.filter Option.is_none rows);
  }

let publish_event t ev = t.publish (event t (Protocol.event_name ev) [])

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
  Fun.protect
    ~finally:(fun () ->
      send (Protocol.Progress { text = ""; fraction = None });
      Atomic.set t.running None)
    (fun () ->
      send (Protocol.Started me.id);
      Jobs.run
        {
          out = (fun s -> send (Out s));
          narrate =
            {
              say = (if narrate then fun s -> send (Narration s) else ignore);
              progress =
                (fun ?fraction text -> send (Progress { text; fraction }));
            };
          cancelled = (fun () -> Atomic.get me.cancelled || Stop.requested ());
        }
        t.domain job)

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
  let surface = function Protocol.Ref r -> r | Rel _ -> "root" in
  match req with
    | Ping -> ()
    | Stat item -> row_or_unnamed t (target t item)
    | List_dir r -> list_dir t r.dir ~after:r.after ~limit:r.limit
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
    | Job r -> run_job t ~send ~narrate:r.narrate r.job
    | Cancel id -> cancel t id
    | Notify_reset -> publish_event t Reset
    | Full_resync ->
        E.stamp_generation ();
        t.hooks.reannounce ()
    | Cursor ->
        E.resync_generation () ^ "|"
        ^ Option.fold ~none:"" ~some:Entry_key.to_string
            (Applied.head E.applied)
    | Sync r -> (
        match E.resync ~full:r.full () with
          | `Incremental n -> Protocol.Incremental n
          | `Full (manifests, failed) -> Protocol.Full { manifests; failed })
    | Ensure_cached r ->
        let path = target t r.item in
        Transfer.check_dest ~roots:(Atomic.get t.dest_roots) r.dest;
        E.assemble_to path r.dest;
        r.dest
    | Fetch_range r ->
        let path = target t r.item in
        if r.offset < 0 || r.length <= 0 then
          invalid "offset ≥ 0 and length > 0 are required";
        Transfer.check_dest ~roots:(Atomic.get t.dest_roots) r.dest;
        let length = E.fetch_range path r.dest ~off:r.offset ~len:r.length in
        { Protocol.local_path = r.dest; offset = r.offset; length }
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
            E.create path ~exclusive:r.exclusive;
            E.close path;
            row_or_unnamed t path)
    | Write r ->
        Transfer.check_staging ~roots:t.staging_roots r.staging;
        mutate (fun () ->
            let path = destination t r.at in
            let e =
              E.write_whole path ~src:r.staging ?base:r.base
                ~exclusive:r.exclusive ()
            in
            {
              Protocol.size = e.size;
              mtime = e.mtime;
              item = row_or_unnamed t path;
            })
    | Mkdir r ->
        mutate (fun () ->
            let path = destination t r.at in
            if r.exclusive || E.kind path <> `Dir then
              E.mkdir path ~exclusive:r.exclusive;
            row_or_unnamed t path)
    | Symlink r ->
        mutate (fun () ->
            let path = destination t r.at in
            E.symlink path ~target:r.link_target ~exclusive:r.exclusive;
            row_or_unnamed t path)
    | Rename r ->
        mutate (fun () ->
            let src = resolve_ref t.engine r.src in
            let dst = destination t r.at in
            (match (E.kind src, E.kind dst) with
              | _, `Absent -> ()
              | `File, `File when not r.noreplace -> ()
              | _ -> Fail.raise_ Fail.Exists "%s exists" dst);
            E.rename ~src ~dst ~exclusive:r.noreplace;
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

let call t req = call_with t ~send:print_line req

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
        Option.iter
          (fun d -> Atomic.set t.dest_roots (d :: Atomic.get t.dest_roots))
          (Ipc.field json "tempDir");
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
                match call t req with
                  | r -> Protocol.encode_reply req r
                  | exception e -> Ipc.failure (Fail.classify e)
              in
              note_reachability t ~bulk:(Protocol.bulk req) reply;
              Ipc.Reply reply
          | exception e -> Ipc.Reply (Ipc.failure (Fail.classify e)))
