open Tsync_core
open Tsync_store
open Tsync_config
module Domain = Tsync_domain.Domain
module R = Tsync_status.Status_report

let store_state_window = 5.
let probe_wait = Health.probe_timeout

type rates = {
  up : Tsync_status.Self_report.rate;
  down : Tsync_status.Self_report.rate;
}

type slot = {
  backend : Config.backend;
  member : Composite.member;
  m : Mutex.t;
  mutable probe : (R.reach * float) option;
  mutable corrupted : R.corrupted;
  mutable refreshing : bool;
  rates : rates;
  copied : Tsync_status.Self_report.rate;
}

type t = {
  domain : Domain.t;
  engine : (module Tsync_sync.Engine.S);
  frontend : unit -> R.frontend option;
  slots : slot list;
}

let create (domain : Domain.t) engine ~frontend =
  {
    domain;
    engine;
    frontend;
    slots =
      List.map
        (fun (backend, member) ->
          {
            backend;
            member;
            m = Mutex.create ();
            probe = None;
            corrupted = Not_checked "no answer yet";
            refreshing = false;
            rates =
              {
                up = Tsync_status.Self_report.rate ~now:(Rt.now ());
                down = Tsync_status.Self_report.rate ~now:(Rt.now ());
              };
            copied = Tsync_status.Self_report.rate ~now:(Rt.now ());
          })
        domain.members;
  }

let corrupted_sample = 1000

(* 07 §5.5: a store that verifies nothing and holds no marker was looked at by
   nobody, which is not clean. *)
let corrupted t (store : Store.t) : R.corrupted =
  let d = t.domain.name in
  match
    Rt.with_timeout ~detach:true probe_wait (fun () ->
        List.length
          (store.list_prefix ~max_keys:(corrupted_sample + 1) (Key.corrupted d)))
  with
    | 0 when not (store.capabilities (Key.domain_prefix d)).verified ->
        Not_checked "the store verifies no write and no verification has run"
    | n ->
        Checked
          { chunks = min n corrupted_sample; truncated = n > corrupted_sample }
    | exception e when not (Rt.is_cancelled e) ->
        Not_checked (Fail.classify e).reason

let refresh_probe t s =
  let store = s.member.store in
  let t0 = Rt.now () in
  let reach =
    match
      Rt.with_timeout ~detach:true probe_wait (fun () ->
          Domain.probe t.domain.name store)
    with
      | () -> R.Reachable { latency_ms = (Rt.now () -. t0) *. 1000. }
      | exception e -> Unreachable (Fail.classify e).reason
  in
  let corrupted =
    match reach with
      | R.Reachable _ -> corrupted t store
      | Unreachable reason -> Not_checked reason
  in
  Mutex.protect s.m (fun () ->
      s.probe <- Some (reach, Rt.now ());
      s.corrupted <- corrupted;
      s.refreshing <- false)

let rec wait_for ~deadline f =
  if f () || Rt.now () >= deadline then ()
  else (
    Rt.sleep 0.05;
    wait_for ~deadline f)

(* A held member is not probed; a stale sample is served while a fresh one is
   taken behind the answer. *)
let reach t s =
  let store = s.member.store in
  if Health.is_held store.health then
    R.Unreachable
      (Option.value ~default:"held down" (Health.describe store.health))
  else (
    let probe =
      Mutex.protect s.m (fun () ->
          let stale =
            match s.probe with
              | None -> true
              | Some (_, at) -> Rt.now () -. at > store_state_window
          in
          let probe = stale && not s.refreshing in
          if probe then s.refreshing <- true;
          probe)
    in
    if probe then Rt.spawn ~name:"status probe" (fun () -> refresh_probe t s);
    wait_for
      ~deadline:(Rt.now () +. probe_wait)
      (fun () -> Mutex.protect s.m (fun () -> s.probe <> None));
    Mutex.protect s.m (fun () ->
        match s.probe with
          | Some (r, _) -> r
          | None -> R.Unreachable "no answer yet"))

let slot_traffic s =
  Option.map
    (fun (tr : Store.traffic) : R.traffic ->
      let now = Rt.now () in
      let up = Atomic.get tr.uploaded and down = Atomic.get tr.downloaded in
      let per = Tsync_status.Self_report.per_second ~now in
      {
        up_bytes = up;
        up_rate = per s.rates.up (float_of_int up);
        down_bytes = down;
        down_rate = per s.rates.down (float_of_int down);
      })
    s.member.store.traffic

let disk (store : Store.t) =
  Option.bind store.local_path (fun path ->
      Option.map
        (fun (s : Fs.space) ->
          {
            R.free_bytes = Int64.to_int s.available;
            total_bytes = Int64.to_int s.total;
          })
        (Fs.disk_space path))

(* A manifest key names its folder by id; the engine knows the folder's path. *)
let job_path t (j : Composite.job_progress) =
  let (module E : Tsync_sync.Engine.S) = t.engine in
  Option.bind j.file (fun (name, _) ->
      Option.bind (Key.of_string j.job) (fun k ->
          Option.bind (Key.folder_of_namespace_key t.domain.name k) (fun id ->
              Option.map (fun dir -> Names.join dir name) (E.path_of_id id))))

let copy_job t (j : Composite.job_progress) : R.copy_job =
  {
    job = j.job;
    path = job_path t j;
    size = Option.map snd j.file;
    chunks = j.chunks;
    checked = j.checked;
    sent = j.sent;
    elapsed = j.elapsed;
    eta =
      (* Chunks already on the copy check fast, so only bytes sent give a pace;
         the rest is taken as missing, an upper bound. *)
        (match j.file with
        | Some (_, size) when j.sent > 0 && j.chunks > 0 ->
            let left =
              float_of_int size
              *. float_of_int (j.chunks - j.checked)
              /. float_of_int j.chunks
            in
            Some (left /. (float_of_int j.sent /. j.elapsed))
        | _ -> None);
  }

let copies t s =
  List.find_map
    (fun (c : Composite.copy_stats) ->
      if c.copy <> s.member.name then None
      else
        Some
          {
            R.owed = c.owed;
            parked = c.parked;
            rate =
              Tsync_status.Self_report.per_second s.copied ~now:(Rt.now ())
                (float_of_int c.done_);
            current = Option.map (copy_job t) c.current;
          })
    (Composite.copy_stats t.domain.composite)

let backend t s : R.backend =
  let b = s.backend and store = s.member.store in
  let specs =
    match Driver.find b.btype with Some d -> d.fields | None -> []
  in
  let reach = reach t s in
  {
    name = b.bname;
    kind = b.btype;
    role = Composite.role_to_string b.role;
    link = b.link;
    config =
      List.map
        (fun (k, (v : Config.shown)) ->
          ( k,
            match v with Secret -> "***" | Shown v -> Config.value_to_string v
          ))
        (Config.masked_fields ~specs b.fields);
    reach;
    corrupted = Mutex.protect s.m (fun () -> s.corrupted);
    health = Health.state store.health;
    disk = disk store;
    copies = copies t s;
    traffic = slot_traffic s;
  }

let settings t : R.settings =
  let d = t.domain.domain and c = t.domain.config in
  let (module E : Tsync_sync.Engine.S) = t.engine in
  let main = E.stated_settings () in
  (* A configuration its main refuses is shown as configured: the refusal is
     the cycle's to report. *)
  let tuning, symlinks =
    try Config.in_force d main with Fail.E _ -> Config.in_force d None
  in
  {
    versioning = d.versioning;
    symlinks;
    chunk_size = Option.value ~default:Chunking.default_chunk_size d.chunk_size;
    chunk_size_default = d.chunk_size = None;
    cache_chunk_size =
      Option.value ~default:Tsync_checkout.Cache.default_cache_chunk_size
        d.cache_chunk_size;
    max_uploads = c.max_uploads;
    max_chunk_buffers = c.max_chunk_buffers;
    max_downloads = c.max_downloads;
    read_only = d.read_only;
    project_lease = tuning.project_lease;
    project_quarantine = tuning.project_quarantine;
    project_settle = tuning.project_settle;
    max_entry_commands = tuning.max_entry_commands;
    batch_delay = tuning.batch_delay;
    project_width = tuning.project_width;
    domain_wide = Config.sources d main;
  }

let domain_body t : R.domain_body =
  let (module E : Tsync_sync.Engine.S) = t.engine in
  let a = E.activity () in
  {
    name = Domain_name.to_string t.domain.name;
    paused = E.is_paused ();
    main_offline =
      List.exists
        (fun s ->
          s.member.role = Composite.Main && Health.is_held s.member.store.health)
        t.slots;
    settings = settings t;
    sync =
      {
        position = a.position;
        pending = a.pending;
        in_flight =
          Option.bind a.position (fun h ->
              if a.pushing then Some (h + 1) else None);
        tree_head = (if a.tree_head > 0 then Some a.tree_head else None);
        cannot_follow =
          Option.map (fun (entry, reason) -> { R.entry; reason }) a.unfollowed;
      };
    set_aside = a.set_aside;
    cache =
      {
        chunks = a.cache.bodies;
        bytes = a.cache.bytes;
        pinned_bytes = a.cache.pinned;
        max_cache = a.max_cache;
      };
    queues =
      {
        pending_files = E.pending_uploads ();
        parked = a.stuck;
        in_flight = a.uploading;
        bytes_owed = a.bytes_owed;
        last_error = a.last_error;
      };
    frontends = Option.to_list (t.frontend ());
    backends = Rt.map_concurrently (backend t) t.slots;
  }

let traffic ts : R.traffic =
  List.fold_left
    (fun (acc : R.traffic) s ->
      match slot_traffic s with
        | Some x ->
            {
              up_bytes = acc.up_bytes + x.up_bytes;
              up_rate = acc.up_rate +. x.up_rate;
              down_bytes = acc.down_bytes + x.down_bytes;
              down_rate = acc.down_rate +. x.down_rate;
            }
        | None -> acc)
    { up_bytes = 0; up_rate = 0.; down_bytes = 0; down_rate = 0. }
    (List.concat_map (fun t -> t.slots) ts)
