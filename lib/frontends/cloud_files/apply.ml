open Tsync_core
open Tsync_owner
open Tsync_cloud_files_rules

(* cloud-files §16 *)
let apply_debounce = 0.2
let apply_retry = 30.

type t = {
  handler : Handler.t;
  root : string;
  take : Take.t;
  unshown : Unshown.t;
  state_file : string;
  m : Mutex.t;
  woke : Condition.t;
  mutable state : Apply_state.t;
  mutable stored : Apply_state.t;
  mutable woken : float option;
  blocked : (string, string) Hashtbl.t;
}

let load state_file =
  match Fs.read_file_opt state_file with
    | Some text ->
        Option.value ~default:Apply_state.fresh (Apply_state.decode text)
    | None -> Apply_state.fresh

let create ~engine:_ ~handler ~root ~take ~unshown ~state_file () =
  {
    handler;
    root;
    take;
    unshown;
    state_file;
    m = Mutex.create ();
    woke = Condition.create ();
    state = load state_file;
    stored = load state_file;
    woken = None;
    blocked = Hashtbl.create 16;
  }

let pending t = Mutex.protect t.m (fun () -> List.length t.state.pending)

let add_pending t refs =
  Mutex.protect t.m (fun () ->
      t.state <-
        {
          t.state with
          pending = List.sort_uniq compare (refs @ t.state.pending);
        })

let wake t =
  Mutex.protect t.m (fun () ->
      if t.woken = None then (
        t.woken <- Some (Unix.gettimeofday () +. apply_debounce);
        Condition.signal t.woke))

let schedule t ref_ =
  add_pending t [ref_];
  wake t

let restart_anchor t =
  Mutex.protect t.m (fun () -> t.state <- { t.state with anchor = "" });
  wake t

let call t request = Rt.run_sync (fun () -> Handler.call t.handler request)
let rows t ref_ = Rt.run_sync (fun () -> Listing.rows t.handler ref_)

let identity_ref (st : Cf.state) =
  Option.map (fun (i : Identity.t) -> i.ref_) (Identity.decode st.identity)

(* §10.2: a folder's place is the chain of its presented names from the root,
   held when the placeholder there carries its reference and was populated. *)
let held_folder t ref_ =
  if ref_ = "root" then Some t.root
  else (
    let domain_path =
      Rt.run_sync (fun () -> Handler.path_of_ref t.handler ref_)
    in
    let rec place dir = function
      | [] -> Some dir
      | leaf :: rest -> (
          match Presentation.presentable leaf with
            | Ok name -> place (Filename.concat dir name) rest
            | Error _ -> None)
    in
    match place t.root (String.split_on_char '/' domain_path) with
      | None -> None
      | Some dir -> (
          match Cf.state dir with
            | Some st
              when st.placeholder && (not st.unpopulated)
                   && identity_ref st = Some ref_ ->
                Some dir
            | _ -> None))

let locate t ref_ : Apply_plan.elsewhere =
  match call t (Stat (Ref ref_)) with
    | exception Fail.E { kind = Absent; _ } -> `Not_held
    | (row : Protocol.row) -> (
        match
          (held_folder t row.parent_ref, Presentation.presentable row.name)
        with
          | Some dir, Ok name -> `Held (dir, name)
          | _ -> `Not_held)

let plan_row (row : Protocol.row) : Apply_plan.row =
  {
    ref_ = row.ref_;
    leaf = row.name;
    is_dir = row.kind = `Dir;
    is_link = row.kind = `Symlink;
    size = row.size;
    mtime = row.mtime;
    content_id = row.content_id;
    read_only = row.read_only;
  }

let placeholder name (row : Apply_plan.row) : Cf.placeholder =
  {
    name;
    is_dir = row.is_dir;
    size = (if row.is_dir then 0 else row.size);
    mtime = (if row.mtime > 0. then row.mtime else Unix.gettimeofday ());
    identity =
      Identity.encode
        (Identity.of_item ~ref_:row.ref_ ~is_dir:row.is_dir
           ~content_id:row.content_id);
    read_only = row.read_only;
  }

(* §10.2: a folder goes only when everything beneath it is an in-sync
   placeholder, whose content is the domain's. *)
let rec all_in_sync path =
  match Cf.state path with
    | Some st when st.placeholder && st.in_sync ->
        (not st.is_dir)
        || Array.for_all
             (fun n -> all_in_sync (Filename.concat path n))
             (try Sys.readdir path with Sys_error _ -> [||])
    | _ -> false

let rec remove path =
  if Sys.is_directory path then (
    Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
    Sys.rmdir path)
  else Sys.remove path

(* Carries one action out; a reason leaves the folder pending. *)
let execute t dir usns (action : Apply_plan.action) =
  let path n = Filename.concat dir n in
  match action with
    | Take name ->
        Take.schedule t.take (path name);
        Some (name ^ " is owed to the domain")
    | Rename { from; to_ } ->
        Sys.rename (path from) (path to_);
        None
    | Move { name; into; as_ } ->
        (* The plan sees no other folder: a name taken there stays, and the
           item goes only when it matches the domain. *)
        if Sys.file_exists (Filename.concat into as_) then (
          if all_in_sync (path name) then remove (path name);
          Some
            (Printf.sprintf "%s moves onto %s, which is taken" name
               (Filename.concat into as_)))
        else (
          Sys.rename (path name) (Filename.concat into as_);
          None)
    | Create { name; row } ->
        Cf.create dir (placeholder name row);
        (* §11: under a pinned folder it is made whole, which the take decides. *)
        Take.schedule t.take (path name);
        None
    | Refresh { name; row } | Update { name; row } ->
        let dehydrate = match action with Refresh _ -> true | _ -> false in
        let usn = Option.value ~default:(-1L) (Hashtbl.find_opt usns name) in
        if Cf.refresh (path name) ~usn (placeholder name row) ~dehydrate then (
          if dehydrate then Take.schedule t.take (path name);
          None)
        else (
          Take.schedule t.take (path name);
          Some (name ^ " changed or is held open, so it was not updated"))
    | Delete name ->
        if all_in_sync (path name) then (
          remove (path name);
          None)
        else Some (name ^ " is gone from the domain but not all in sync here")

let children dir =
  let usns = Hashtbl.create 16 in
  let children =
    List.filter_map
      (fun name ->
        if Names.is_temp_name name then None
        else (
          let path = Filename.concat dir name in
          match (Cf.state path, Unix.LargeFile.stat path) with
            | None, _ | (exception Unix.Unix_error _) -> None
            | Some st, stat ->
                Hashtbl.replace usns name st.usn;
                Some
                  {
                    Apply_plan.name;
                    owed = (not st.placeholder) || not st.in_sync;
                    identity =
                      (if st.placeholder then Identity.decode st.identity
                       else None);
                    size = Int64.to_int stat.st_size;
                    mtime = stat.st_mtime;
                    read_only = stat.st_perm land 0o200 = 0;
                  }))
      (Array.to_list (try Sys.readdir dir with Sys_error _ -> [||]))
  in
  (children, usns)

(* A folder stays pending while retried, so its reasons are logged only when
   they change. *)
let report_blocked t dir reasons =
  match reasons with
    | [] -> Hashtbl.remove t.blocked dir
    | first :: _ ->
        if Hashtbl.find_opt t.blocked dir <> Some first then (
          Hashtbl.replace t.blocked dir first;
          Log.info "cloud_files: applying %s: %s" dir first)

(* §10.2: [true] once the folder matches the domain, or when the sync root
   does not hold it, which leaves nothing to apply. *)
let apply_folder t ref_ =
  match held_folder t ref_ with
    | None -> true
    | Some dir ->
        let rows = rows t ref_ in
        let children, usns = children dir in
        ignore
          (Unshown.present t.unshown
             ~on_disk:(fun n ->
               List.exists (fun (c : Apply_plan.child) -> c.name = n) children)
             rows);
        let rows = List.map plan_row rows in
        let actions =
          Apply_plan.plan ~fold:Cf.upcase ~rows ~children ~locate:(locate t)
        in
        let reasons =
          List.filter_map
            (fun action ->
              match execute t dir usns action with
                | reason -> reason
                | exception e -> Some (Printexc.to_string e))
            actions
        in
        report_blocked t dir reasons;
        reasons = []

(* §10.3, stale: every folder the sync root holds and has populated. *)
let populated_folders t =
  let rec walk dir acc =
    Array.fold_left
      (fun acc name ->
        let path = Filename.concat dir name in
        match Cf.state path with
          | Some st when st.is_dir && st.placeholder && not st.unpopulated -> (
              match identity_ref st with
                | Some r -> walk path (r :: acc)
                | None -> acc)
          | _ -> acc)
      acc
      (try Sys.readdir dir with Sys_error _ -> [||])
  in
  walk t.root ["root"]

let op_folders = function
  | Protocol.Put_op { parent_ref; _ }
  | Delete_op { parent_ref; _ }
  | Mkdir_op { parent_ref; _ }
  | Rmdir_op { parent_ref; _ } ->
      [parent_ref]
  | Rename_op { parent_ref; src_parent_ref; _ } -> [parent_ref; src_parent_ref]

let store t =
  let state = Mutex.protect t.m (fun () -> t.state) in
  if state <> t.stored then (
    Fs.replace t.state_file (Apply_state.encode state);
    t.stored <- state)

let rec follow t =
  let anchor = Mutex.protect t.m (fun () -> t.state.anchor) in
  let more =
    match call t (Changes_since { anchor; limit = None }) with
      | Stale ->
          let cursor = call t Cursor in
          add_pending t (populated_folders t);
          Mutex.protect t.m (fun () ->
              t.state <- { t.state with anchor = cursor });
          false
      | Changes { cursor; more; ops; _ } ->
          add_pending t (List.concat_map op_folders ops);
          Mutex.protect t.m (fun () ->
              t.state <- { t.state with anchor = cursor });
          more
  in
  let pending = Mutex.protect t.m (fun () -> t.state.pending) in
  let unfinished =
    List.filter
      (fun ref_ ->
        match apply_folder t ref_ with
          | finished -> not finished
          | exception e ->
              Log.info "cloud_files: applying %s: %s" ref_
                (Printexc.to_string e);
              true)
      pending
  in
  Mutex.protect t.m (fun () ->
      t.state <-
        {
          t.state with
          pending =
            List.filter
              (fun r -> List.mem r unfinished || not (List.mem r pending))
              t.state.pending;
        });
  store t;
  if more then follow t

(* Sleeps until woken, then until the debounce has passed. *)
let rec loop t =
  let at =
    Mutex.protect t.m (fun () ->
        let rec woken () =
          match t.woken with
            | Some at -> at
            | None ->
                Condition.wait t.woke t.m;
                woken ()
        in
        woken ())
  in
  Thread.delay (Float.max 0. (at -. Unix.gettimeofday ()));
  Mutex.protect t.m (fun () -> t.woken <- None);
  (try follow t
   with e -> Log.warn "cloud_files: apply: %s" (Printexc.to_string e));
  loop t

let rec retry t =
  Thread.delay apply_retry;
  if pending t > 0 then wake t;
  retry t

let start t =
  ignore (Thread.create (fun () -> loop t) ());
  ignore (Thread.create (fun () -> retry t) ());
  wake t
