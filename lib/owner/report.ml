open Tsync_core
open Tsync_store
open Tsync_config
module Domain = Tsync_domain.Domain
module R = Tsync_status.Status_report

let store_state_window = 5.
let listing_grace = 2.
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
  mutable listing : R.journal option;
  mutable refreshing : bool;
  rates : rates;
  copied : Tsync_status.Self_report.rate;
}

type t = {
  domain : Domain.t;
  engine : (module Tsync_sync.Engine.S);
  frontend : unit -> R.frontend option;
  slots : slot list;
  client : string;
}

let create (domain : Domain.t) engine ~frontend =
  {
    domain;
    engine;
    frontend;
    client = Tsync_checkout.Identity.client_uuid domain.data_dir;
    slots =
      List.map
        (fun (backend, member) ->
          {
            backend;
            member;
            m = Mutex.create ();
            probe = None;
            listing = None;
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

(* 07 §5.5: entries newer than the mark and authored by another client; one
   already in the applied log is not behind, whatever the mark says. *)
let behind t entries =
  let (module E : Tsync_sync.Engine.S) = t.engine in
  let mark = Tsync_sync.Mark.read ~data_dir:t.domain.data_dir t.domain.name in
  List.length
    (List.filter
       (fun (k, _) ->
         Tsync_sync.Entry_key.client k <> t.client
         && (not (Tsync_sync.Applied.contains E.applied k))
         &&
           match mark with
           | Some m -> Tsync_sync.Entry_key.compare k m > 0
           | None -> true)
       entries)

let refresh t s =
  let store = s.member.store in
  let t0 = Rt.now () in
  let reach =
    match
      Rt.with_timeout probe_wait (fun () -> Domain.probe t.domain.name store)
    with
      | () -> R.Reachable { latency_ms = (Rt.now () -. t0) *. 1000. }
      | exception e -> Unreachable (Fail.classify e).reason
  in
  Mutex.protect s.m (fun () -> s.probe <- Some (reach, Rt.now ()));
  let listing =
    match
      Tsync_sync.Journal.list_entries
        (Tsync_sync.Journal.create t.domain.name store)
    with
      | entries ->
          R.Entries { entries = List.length entries; behind = behind t entries }
      | exception e -> Unreadable (Fail.classify e).reason
  in
  Mutex.protect s.m (fun () ->
      s.listing <- Some listing;
      s.refreshing <- false)

let rec wait_for ~deadline f =
  if f () || Rt.now () >= deadline then ()
  else (
    Rt.sleep 0.05;
    wait_for ~deadline f)

(* A held member is not probed; a stale sample is served while a fresh one is
   taken behind the answer. *)
let reach_and_journal t s =
  let store = s.member.store in
  if Health.is_held store.health then
    ( R.Unreachable
        (Option.value ~default:"held down" (Health.describe store.health)),
      Mutex.protect s.m (fun () -> Option.value ~default:R.Counting s.listing)
    )
  else (
    let start =
      Mutex.protect s.m (fun () ->
          let stale =
            match s.probe with
              | None -> true
              | Some (_, at) -> Rt.now () -. at > store_state_window
          in
          let start = stale && not s.refreshing in
          if start then s.refreshing <- true;
          start)
    in
    if start then Rt.spawn ~name:"status probe" (fun () -> refresh t s);
    wait_for
      ~deadline:(Rt.now () +. probe_wait)
      (fun () -> Mutex.protect s.m (fun () -> s.probe <> None));
    wait_for
      ~deadline:(Rt.now () +. listing_grace)
      (fun () ->
        Mutex.protect s.m (fun () -> s.listing <> None || not s.refreshing));
    Mutex.protect s.m (fun () ->
        ( (match s.probe with
            | Some (r, _) -> r
            | None -> R.Unreachable "no answer yet"),
          Option.value ~default:R.Counting s.listing )))

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

let copies t s =
  List.find_map
    (fun (c : Composite.copy_stats) ->
      if c.copy <> s.member.name then None
      else (
        let rate =
          Tsync_status.Self_report.per_second s.copied ~now:(Rt.now ())
            (float_of_int c.done_)
        in
        Some
          {
            R.owed = c.owed;
            parked = c.parked;
            rate;
            eta =
              (if c.owed > 0 && rate > 0. then Some (float_of_int c.owed /. rate)
               else None);
          }))
    (Composite.copy_stats t.domain.composite)

let backend t s : R.backend =
  let b = s.backend and store = s.member.store in
  let specs =
    match Driver.find b.btype with Some d -> d.fields | None -> []
  in
  let reach, journal = reach_and_journal t s in
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
    journal;
    corrupted = Not_checked "no verification has run";
    health = Health.state store.health;
    disk = disk store;
    copies = copies t s;
    traffic = slot_traffic s;
  }

let settings t : R.settings =
  let d = t.domain.domain and c = t.domain.config in
  {
    versioning = d.versioning;
    symlinks = d.symlinks;
    chunk_size = Option.value ~default:Chunking.default_chunk_size d.chunk_size;
    chunk_size_default = d.chunk_size = None;
    cache_chunk_size =
      Option.value ~default:Tsync_checkout.Cache.default_cache_chunk_size
        d.cache_chunk_size;
    max_uploads = c.max_uploads;
    max_chunk_buffers = c.max_chunk_buffers;
    max_downloads = c.max_downloads;
    read_only = d.read_only;
  }

let domain_body t : R.domain_body =
  let (module E : Tsync_sync.Engine.S) = t.engine in
  let a = E.activity () in
  let unapplied = E.unapplied () in
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
        hold = (match E.bridge () with Incremental -> None | Hold r -> Some r);
        mark_age = a.mark_age;
        unapplied_entries = List.length unapplied;
        unapplied_reason = Option.map snd (List.nth_opt unapplied 0);
        parked_metadata = List.length (E.parked ());
      };
    cache =
      {
        chunks = a.cache.bodies;
        bytes = a.cache.bytes;
        pinned_bytes = a.cache.pinned;
        max_cache = a.max_cache;
      };
    wal =
      {
        intent = a.intent;
        prepared = a.prepared;
        executed = a.executed;
        stuck = a.stuck;
        last_error = a.last_error;
      };
    queues =
      {
        pending_files = E.pending_uploads ();
        pending_metadata = E.pending_metadata ();
        in_flight = a.in_flight;
        bytes_owed = a.bytes_owed;
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
