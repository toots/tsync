open Tsync_core
open Tsync_ipc
open Tsync_sync

type hooks = {
  changed : string list -> unit;
  surface_evicted : string -> unit;
  surface_restored : string -> unit;
  reannounce : unit -> unit;
  status_fields : unit -> (string * Ipc.json) list;
  stats_fields : unit -> (string * Ipc.json) list;
}

let no_hooks =
  {
    changed = ignore;
    surface_evicted = ignore;
    surface_restored = ignore;
    reannounce = ignore;
    status_fields = (fun () -> []);
    stats_fields = (fun () -> []);
  }

type t = {
  domain : Tsync_domain.Domain.t;
  engine : (module Engine.S);
  hooks : hooks;
  publish : Ipc.json -> int;
  stats : string list -> Ipc.json;
  stop : unit -> unit;
  dest_roots : string list Atomic.t;
  staging_roots : string list;
  answered_unreachable : bool Atomic.t;
}

let default_pin_keep = 10. *. 86400.
let page_limit = 1000
let event_ids = Atomic.make 0

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
let member req k = match req with `Assoc l -> List.assoc_opt k l | _ -> None

let str req k =
  match member req k with
    | Some (`String s) -> Some s
    | None | Some `Null -> None
    | Some _ -> invalid "%s must be a string" k

let required req k =
  match str req k with Some s -> s | None -> invalid "%s is required" k

let flag req k =
  match member req k with
    | Some (`Bool b) -> b
    | None | Some `Null -> false
    | Some _ -> invalid "%s must be a boolean" k

let int req k =
  match member req k with
    | Some (`Int i) -> Some i
    | None | Some `Null -> None
    | Some _ -> invalid "%s must be an integer" k

let number req k =
  match member req k with
    | Some (`Int i) -> Some (float_of_int i)
    | Some (`Float f) -> Some f
    | None | Some `Null -> None
    | Some _ -> invalid "%s must be a number" k

(* 08 §2.3: [None] when the row's container has no id on this client. *)
let row (module E : Engine.S) ~root_name path =
  let st = E.stat path in
  let id_of p = Option.map Folder_id.to_string (E.folder_id p) in
  let parent_ref () =
    if path = "" then Some "root"
    else
      Option.map
        (fun id -> Names.ref_to_string (Names.dir_ref id))
        (id_of (Names.parent_of path))
  in
  let ref_ =
    if path = "" then Some "root"
    else (
      match st.kind with
        | `Dir ->
            Option.map
              (fun id -> Names.ref_to_string (Names.dir_ref id))
              (Option.map Folder_id.to_string st.folder_id)
        | `File | `Symlink ->
            Option.map
              (fun id ->
                Names.ref_to_string (Names.File (id, Names.leaf_of path)))
              (id_of (Names.parent_of path)))
  in
  match (ref_, parent_ref ()) with
    | Some r, Some pr ->
        let name = if path = "" then root_name else Names.leaf_of path in
        let common kind size mtime etag uploaded =
          [
            ("ref", `String r);
            ("parentRef", `String pr);
            ("name", `String name);
            ("kind", `String kind);
            ("size", `Int size);
            ("mtime", `Float mtime);
            ("etag", `String etag);
            ("isUploaded", `Bool uploaded);
          ]
        in
        Some
          (`Assoc
             (match st.kind with
               | `Dir ->
                   let etag =
                     match st.folder_id with
                       | Some id when path <> "" -> Folder_id.to_string id
                       | _ -> ".tsync-root"
                   in
                   common "dir" 0 0. etag true
               | `Symlink ->
                   common "symlink" st.size st.mtime st.etag (not st.staged)
                   @ Option.fold ~none:[]
                       ~some:(fun t -> [("symlinkTarget", `String t)])
                       st.target
               | `File ->
                   let availability =
                     match E.availability path with
                       | `Online_only ->
                           [("availability", `String "online-only")]
                       | `Cached -> [("availability", `String "cached")]
                       | `Pinned until ->
                           [
                             ("availability", `String "pinned");
                             ("pinnedUntil", `Float until);
                           ]
                   in
                   common "file" st.size st.mtime st.etag (not st.staged)
                   @ Option.fold ~none:[]
                       ~some:(fun c -> [("contentId", `String c)])
                       st.content_id
                   @ availability))
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

let target t req =
  match (str req "ref", str req "rel") with
    | Some r, _ -> resolve_ref t.engine r
    | None, Some rel -> resolve_rel t.engine rel
    | None, None -> invalid "ref or rel is required"

(* 08 §3.5: a destination is a parent folder and a valid leaf. *)
let destination t req =
  let (module E : Engine.S) = t.engine in
  let parent = resolve_ref t.engine (required req "parentRef") in
  if E.kind parent <> `Dir then invalid "parentRef does not name a folder";
  let name = required req "name" in
  if not (Names.valid_leaf name) then invalid "invalid name %S" name;
  Names.join parent name

let is_bulk = function
  | "ensure_cached" | "fetch_range" | "evict" | "restore" | "sync" | "prune" ->
      true
  | _ -> false

let is_mutation = function
  | "create" | "write" | "mkdir" | "symlink" | "rename" | "delete" | "rmdir"
  | "revert" ->
      true
  | _ -> false

let refused_while_paused = function
  | "revert" | "share" | "sync" -> true
  | _ -> false

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

let list_dir t req =
  let (module E : Engine.S) = t.engine in
  let path = target t req in
  if E.kind path <> `Dir then invalid "not a folder";
  let after = Option.value ~default:"" (str req "after") in
  let limit = Option.value ~default:page_limit (int req "limit") in
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
  let unnamed = List.length (List.filter Option.is_none rows) in
  Ipc.ok
    ([("items", `List (List.filter_map Fun.id rows))]
    @ (match (more, List.rev page) with
      | true, (last : E.entry) :: _ -> [("next", `String last.name)]
      | _ -> [])
    @ if unnamed > 0 then [("unnamed", `Int unnamed)] else [])

let status t =
  let (module E : Engine.S) = t.engine in
  Ipc.ok
    ([
       ("domain", `String (domain_name t));
       ("running", `Bool true);
       ("readOnly", `Bool t.domain.domain.read_only);
       ("paused", `Bool (E.is_paused ()));
       ("pendingUploads", `Int (E.pending_uploads ()));
       ("pendingDownloads", `Int 0);
       ("uploading", `List []);
       ("downloading", `List []);
     ]
    @ t.hooks.status_fields ())

let item t path = [("item", row_or_unnamed t path)]

let act t action req =
  let (module E : Engine.S) = t.engine in
  let mutate f = E.atomically f in
  match action with
    | "ping" -> Ipc.ok []
    | "stat" -> (
        match row_or_unnamed t (target t req) with
          | `Assoc fields -> Ipc.ok fields
          | _ -> assert false)
    | "list_dir" -> list_dir t req
    | "status" -> status t
    | "stats" ->
        t.stats
          (List.filter (( <> ) "")
             (String.split_on_char ','
                (Option.value ~default:"" (str req "arg"))))
    | "stop" ->
        t.stop ();
        Ipc.ok []
    | "poll" ->
        Rt.spawn ~name:"poll" E.poll;
        Ipc.ok []
    | "pause" ->
        E.set_paused (str req "arg" <> Some "off");
        Ipc.ok [("paused", `Bool (E.is_paused ()))]
    | "retry" -> Ipc.ok [("readopted", `Int (E.rearm ()))]
    | "notify_reset" ->
        Ipc.ok [("delivered", `Int (t.publish (event t "reset" [])))]
    | "full_resync" ->
        E.stamp_generation ();
        t.hooks.reannounce ();
        Ipc.ok []
    | "cursor" ->
        let head =
          Option.fold ~none:"" ~some:Entry_key.to_string
            (Applied.head E.applied)
        in
        Ipc.ok [("cursor", `String (E.resync_generation () ^ "|" ^ head))]
    | "sync" -> (
        match E.resync ~full:(str req "arg" = Some "full") () with
          | `Incremental n ->
              Ipc.ok [("mode", `String "incremental"); ("applied", `Int n)]
          | `Full (walked, failed) ->
              Ipc.ok
                [
                  ("mode", `String "full");
                  ("manifests", `Int walked);
                  ("failed", `Int failed);
                ])
    | "ensure_cached" ->
        let path = target t req in
        let dest = required req "dest" in
        Transfer.check_dest ~roots:(Atomic.get t.dest_roots) dest;
        E.assemble_to path dest;
        Ipc.ok [("localPath", `String dest)]
    | "fetch_range" ->
        let path = target t req in
        let dest = required req "dest" in
        let offset = Option.value ~default:(-1) (int req "offset") in
        let length = Option.value ~default:0 (int req "length") in
        if offset < 0 || length <= 0 then
          invalid "offset ≥ 0 and length > 0 are required";
        Transfer.check_dest ~roots:(Atomic.get t.dest_roots) dest;
        let served = E.fetch_range path dest ~off:offset ~len:length in
        Ipc.ok
          [
            ("localPath", `String dest);
            ("offset", `Int offset);
            ("length", `Int served);
          ]
    | "download_progress" -> Ipc.ok [("active", `Bool false)]
    | "evict" ->
        let path = target t req in
        let evicted, failed = each_file t path E.evict in
        t.hooks.surface_evicted (Option.value ~default:"root" (str req "ref"));
        Ipc.ok [("evicted", `Int evicted); ("failed", `Int failed)]
    | "restore" ->
        let path = target t req in
        let keep = Option.value ~default:default_pin_keep (number req "keep") in
        let restored, failed = each_file t path (fun p -> E.pin p ~keep) in
        t.hooks.surface_restored (Option.value ~default:"root" (str req "ref"));
        Ipc.ok [("restored", `Int restored); ("failed", `Int failed)]
    | "create" ->
        mutate (fun () ->
            let path = destination t req in
            E.create path ~exclusive:(flag req "exclusive");
            E.close path;
            Ipc.ok (item t path))
    | "write" ->
        (* ponytail: [await] is not honoured yet; the Android host needs it. *)
        let staging = required req "staging" in
        Transfer.check_staging ~roots:t.staging_roots staging;
        mutate (fun () ->
            let path = destination t req in
            let e =
              E.write_whole path ~src:staging ?base:(str req "base")
                ~exclusive:(flag req "exclusive") ()
            in
            Ipc.ok
              ([("size", `Int e.size); ("mtime", `Float e.mtime)] @ item t path))
    | "mkdir" ->
        mutate (fun () ->
            let path = destination t req in
            let exclusive = flag req "exclusive" in
            if exclusive || E.kind path <> `Dir then E.mkdir path ~exclusive;
            Ipc.ok (item t path))
    | "symlink" ->
        mutate (fun () ->
            let path = destination t req in
            E.symlink path ~target:(required req "target")
              ~exclusive:(flag req "exclusive");
            Ipc.ok (item t path))
    | "rename" ->
        mutate (fun () ->
            let src = resolve_ref t.engine (required req "ref") in
            let dst = destination t req in
            let exclusive = flag req "noreplace" || flag req "exclusive" in
            (match (E.kind src, E.kind dst) with
              | _, `Absent -> ()
              | `File, `File when not exclusive -> ()
              | _ -> Fail.raise_ Fail.Exists "%s exists" dst);
            E.rename ~src ~dst ~exclusive;
            Ipc.ok (item t dst))
    | "delete" ->
        mutate (fun () ->
            let path = target t req in
            if E.kind path = `Dir then invalid "a folder is removed with rmdir";
            E.delete path;
            Ipc.ok [])
    | "rmdir" ->
        mutate (fun () ->
            let path = target t req in
            if path = "" then invalid "the root cannot be removed";
            if E.kind path <> `Dir then invalid "not a folder";
            rmdir_subtree t.engine path;
            Ipc.ok [])
    | a -> invalid "unknown action: %s" a

(* failure-model §8.2: the reply is bounded, the work behind it is not. *)
let bounded f =
  let p = Rt.Promise.create () in
  Rt.spawn ~name:"request" (fun () ->
      ignore
        (Rt.Promise.try_resolve_result p (try Ok (f ()) with e -> Error e)));
  try Rt.with_timeout Ipc.request_deadline (fun () -> Rt.Promise.await p)
  with Rt.Timeout -> Fail.raise_ Fail.Deadline "still in progress; retry"

let answer t req =
  let action = Option.value ~default:"" (Ipc.field req "action") in
  let reply =
    match
      let action = required req "action" in
      if action = "subscribe" then (
        Option.iter
          (fun d -> Atomic.set t.dest_roots (d :: Atomic.get t.dest_roots))
          (str req "tempDir");
        `Subscribe)
      else (
        let (module E : Engine.S) = t.engine in
        if is_mutation action && t.domain.domain.read_only then
          Fail.raise_ Fail.Read_only "%s is read-only" (domain_name t);
        if refused_while_paused action && E.is_paused () then
          Fail.raise_ Fail.Paused "%s is paused" (domain_name t);
        `Reply
          (if is_bulk action || action = "stop" || action = "ping" then
             act t action req
           else bounded (fun () -> act t action req)))
    with
      | `Subscribe -> `Subscribe
      | `Reply r -> `Reply r
      | exception e -> `Reply (Ipc.failure (Fail.classify e))
  in
  match reply with
    | `Subscribe ->
        Ipc.Subscribe (domain_name t, Ipc.ok [], [event t "recovered" []])
    | `Reply r ->
        (match Ipc.field r "code" with
          | Some "unreachable" -> Atomic.set t.answered_unreachable true
          | Some _ -> ()
          | None ->
              if is_bulk action && Atomic.exchange t.answered_unreachable false
              then ignore (t.publish (event t "recovered" [])));
        Ipc.Reply r
