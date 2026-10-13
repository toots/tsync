open Tsync_core
open Tsync_checkout

module type S = Engine_intf.S

let pause_flag ~data_dir d =
  List.fold_left Filename.concat data_dir ["paused"; Domain_name.to_string d]

let feed_retention = 30. *. 86400.
let feed_watermark_max_age = 180. *. 86400.

module Make (C : Engine_ctx.S) = struct
  include Rsync.Make (C)

  let resync_generation () =
    match Fs.read_file_opt resync_generation_path with
      | Some s -> String.trim s
      | None -> ""

  let dropped_path =
    Filename.concat C.data_dir ("feed-dropped-" ^ Domain_name.to_string d)

  (* 08 §3.6: the feed key of the oldest anchor the feed's consumer may
     present, and when it last moved. [None]: no consumer holds an anchor; a
     key of [None] is "before every line". A lost or torn record reads as
     absent. *)
  let read_watermark () =
    match Fs.read_file_opt watermark_path with
      | None -> None
      | Some s -> (
          match String.split_on_char ' ' (String.trim s) with
            | [key; ms] -> (
                match (key, Int64.of_string_opt ms) with
                  | "", Some ms -> Some (None, ms)
                  | k, Some ms ->
                      Option.map (fun k -> (Some k, ms)) (Feed_key.parse k)
                  | _, None -> None)
            | [ms] -> Option.map (fun ms -> (None, ms)) (Int64.of_string_opt ms)
            | _ -> None)

  let write_watermark key =
    Fs.durable_replace watermark_path
      (Printf.sprintf "%s %.0f"
         (Option.fold ~none:"" ~some:Feed_key.to_string key)
         (Unix.gettimeofday () *. 1000.))

  let anchor_of gen key =
    gen ^ "|" ^ Option.fold ~none:"" ~some:Feed_key.to_string key

  let cursor () =
    Mutex.protect feed_m (fun () ->
        let head = Applied.head applied in
        if read_watermark () = None then write_watermark head;
        anchor_of (resync_generation ()) head)

  let changes_since anchor ~limit =
    Mutex.protect feed_m (fun () ->
        let gen = resync_generation () in
        match String.index_opt anchor '|' with
          | None -> `Stale
          | Some i -> (
              let key_s =
                String.sub anchor (i + 1) (String.length anchor - i - 1)
              in
              let key =
                if key_s = "" then Some None
                else Option.map Option.some (Feed_key.parse key_s)
              in
              match key with
                | None -> `Stale
                | Some _ when String.sub anchor 0 i <> gen -> `Stale
                | Some None when Fs.exists dropped_path -> `Stale
                | Some key ->
                    write_watermark key;
                    let head = Applied.head applied in
                    if Option.equal Feed_key.equal key head then
                      `Page (anchor_of gen head, false, [])
                    else (
                      match Applied.since applied key limit with
                        | `Stale -> `Stale
                        | `Page (pg : Applied.page) ->
                            let cursor =
                              match List.rev pg.entries with
                                | (k, _) :: _ -> anchor_of gen (Some k)
                                | [] -> anchor
                            in
                            `Page
                              (cursor, pg.more, List.concat_map snd pg.entries))
              ))

  (* 03 §2.9: held back by the watermark until it lapses. *)
  let prune_applied () =
    let hold =
      Mutex.protect feed_m (fun () ->
          match read_watermark () with
            | None -> `Nothing
            | Some (_, ms)
              when Unix.gettimeofday () -. (Int64.to_float ms /. 1000.)
                   > feed_watermark_max_age ->
                Log.warn
                  "%s: the change feed's consumer has not read it for %.0f \
                   days; its anchor stops holding the applied log"
                  (Domain_name.to_string d)
                  (feed_watermark_max_age /. 86400.);
                `Nothing
            | Some (None, _) -> `Everything
            | Some (Some k, _) -> `From k)
    in
    Applied.prune ~hold
      ~before_drop:(fun () ->
        if not (Fs.exists dropped_path) then Fs.durable_replace dropped_path "")
      applied ~now:(Unix.gettimeofday ()) ~keep:feed_retention

  let trim_cache () = ignore (Cache.enforce_cap cache)

  (* 03 §3.4: a cycle now, which pushes what is due and leaves the rest to
     the batch delay. *)
  let poll () =
    Dqueue.rescan uploads;
    Tsync_store.Composite.rescan C.composite;
    nudge ()

  (* 04 §4.6: the version's manifest becomes the key's local value, a local
     operation the cycle commits. *)
  let revert ?version path =
    if not C.versioning then
      Fail.raise_ Fail.Refused "%s does not keep versions"
        (Domain_name.to_string d);
    let parent = require_parent path and leaf = Names.leaf_of path in
    let versions = R.list_versions parent leaf in
    let chosen =
      match version with
        | None -> List.nth_opt versions 0
        | Some ns -> List.find_opt (fun (v, _) -> Int64.equal v ns) versions
    in
    match chosen with
      | None -> Fail.absent "%s: no such version" path
      | Some (_, entry) ->
          let m =
            match Manifest.decode (R.get_version entry) with
              | Some m -> Manifest.rename m leaf
              | None -> Fail.corrupt "%s: the version is not a manifest" path
          in
          with_meta (fun () -> install path m)

  (* Every maximal run of exactly 16 lowercase hex characters: the bodies a
     set-aside manifest may name. *)
  let hex_runs s =
    let n = String.length s in
    let rec go i acc =
      if i >= n then acc
      else if Names.is_hexlower s.[i] then (
        let j = ref i in
        while !j < n && Names.is_hexlower s.[!j] do
          incr j
        done;
        go !j (if !j - i = 16 then String.sub s i 16 :: acc else acc))
      else go (i + 1) acc
    in
    go 0 []

  let staged_set_aside = Atomic.make 0

  let sweep_local_temps () =
    let root = Mirror.root mirror in
    let rec sweep_temps dir =
      Fs.sweep_temps ~older_than:86400. dir;
      List.iter
        (fun n ->
          let p = Filename.concat dir n in
          if Fs.kind p = `Dir then sweep_temps p)
        (Fs.readdir dir)
    in
    if Fs.is_dir root then sweep_temps root

  (* 04 §4.9: a removed folder's record is kept while a feed line may still
     name the folder. *)
  let daily_maintenance () =
    sweep_local_temps ();
    Mirror.sweep_removed_records mirror ~older_than:feed_retention

  (* 04 §4.10, before anything is served. *)
  let recover () =
    let root = Mirror.root mirror in
    Cache.sweep_at_start cache;
    let named = Hashtbl.create 64 in
    let staged_dir = Filename.concat root "staged" in
    Staged.fold staged
      (fun () -> function
        | `Edit (_, e) ->
            List.iter
              (fun b -> Hashtbl.replace named b ())
              (Staged.bodies_named e)
        | `Bad p ->
            Atomic.incr staged_set_aside;
            let body = Option.value ~default:"" (Fs.read_file_opt p) in
            let base = Filename.basename p in
            if not (Staged.is_set_aside_name base) then (
              Fs.rename p (Staged.set_aside_path p);
              Log.warn "set aside the undecodable staged manifest %s" p);
            List.iter (fun b -> Hashtbl.replace named b ()) (hex_runs body))
      ();
    recover_local ();
    List.iter
      (fun sub ->
        List.iter
          (fun b ->
            if (not (Names.is_temp_name b)) && not (Hashtbl.mem named b) then
              ignore
                (Fs.release
                   (Filename.concat (Filename.concat staged_dir sub) b)))
          (Fs.readdir (Filename.concat staged_dir sub)))
      ["chunks"; "whole"];
    (* 04 §4.10 step 9: the index first, so it sees every marker minted here;
       no read path mints a file id. *)
    Mirror.load_file_ids mirror;
    let minted = Mirror.backfill_file_ids mirror in
    List.iter
      (fun (p, _) -> ignore (Mirror.ensure_file_id mirror p))
      (Staged.edits staged);
    if minted > 0 then Log.info "gave file ids to %d files" minted

  let paused_path = pause_flag ~data_dir:C.data_dir d

  (* An owner that never starts its queues still answers for the durable
     state (pitfall A-10.14). *)
  let () = Atomic.set paused (Fs.exists paused_path)

  let set_paused on =
    if on then Fs.durable_replace paused_path ""
    else if Fs.release paused_path then
      Fs.fsync_dir (Filename.dirname paused_path);
    Atomic.set paused on;
    (if on then Dqueue.pause else Dqueue.resume) uploads;
    (if on then Tsync_store.Composite.pause else Tsync_store.Composite.resume)
      C.composite;
    if not on then request_cycle ()

  let is_paused () = Atomic.get paused

  let stated_settings () =
    match R.stated () with `Stated s -> Some s | `Unstated | `Unknown -> None

  let start ?(background = true) () =
    let is_paused = Fs.exists paused_path in
    Atomic.set paused is_paused;
    recover ();
    (* Every reader skips a temporary, so dead ones are swept behind the
       start: the walk is an lstat per file of the domain. *)
    Rt.spawn ~name:"sweep temporaries" (fun () ->
        try sweep_local_temps () with
          | (Stop.Stopping | Rt.Cancelled) as e -> raise e
          | e -> Log.warn "temporaries not swept: %s" (Printexc.to_string e));
    (* 01 §3.5: the main's chunk size is asked from owner start on. *)
    (try ignore (R.chunk_size ()) with Fail.E _ -> ());
    Dqueue.start ~paused:is_paused uploads run_upload;
    Dqueue.rescan uploads;
    Tsync_store.Composite.start ~paused:is_paused C.composite;
    if background then Rt.spawn ~name:"cycle" cycle_loop

  (* 07 §3.4: the upload queue, raced against a fraction of the grace; a last
     cycle; the cursor; then the copies. *)
  let drain ?(grace = Stop.grace) () =
    let deadline = Rt.now () +. grace in
    if not (Atomic.get paused) then (
      (try
         Rt.with_timeout (0.8 *. grace) (fun () ->
             Dqueue.settle ~timeout:grace uploads)
       with Rt.Timeout ->
         Log.info "uploads still busy after the grace; the rest is owed on disk");
      try
        Rt.with_timeout
          (max 0.1 (deadline -. Rt.now ()))
          (fun () -> ignore (run_cycle ()))
      with
        | (Stop.Stopping | Rt.Cancelled) as e -> raise e
        | e ->
            Log.info "the last cycle did not complete: %s"
              (Printexc.to_string e));
    Tsync_remote.Log_store.cursor_flush log;
    let left = deadline -. Rt.now () in
    if left > 0. then Tsync_store.Composite.settle ~timeout:left C.composite;
    Mirror.save_file_ids mirror

  let resync ?narrate ?(full = false) () : Engine_intf.synced =
    if C.lazy_tree then
      Fail.raise_ Fail.Refused "a lazy tree pulls its folders; it has no sync";
    if Atomic.get paused then
      Fail.raise_ Fail.Refused "%s is paused" (Domain_name.to_string d);
    let c = run_cycle ?narrate ~full () in
    (match c.arrival with
      | `State _ -> with_meta (fun () -> Mirror.rebuild_index mirror)
      | `Entries _ -> ());
    {
      arrival = c.arrival;
      changed = c.changed;
      committed = c.committed;
      pending = Sync_state.pending_count sync_state;
    }

  let pending_uploads () = Dqueue.pending uploads
  let pending_changes () = Sync_state.pending_count sync_state

  let upload_of id =
    match Dqueue.Records.read upload_log id with
      | `Body body -> Local_ops.upload_kind.decode body
      | `Gone -> None

  let upload_path id =
    Option.bind (upload_of id) (fun (u : Local_ops.upload) -> path_of u.file)

  let activity () : Engine_intf.activity =
    let parked = Dqueue.parked uploads and retrying = Dqueue.retrying uploads in
    {
      position = position ();
      pending = Sync_state.pending_count sync_state;
      pushing = Sync_state.in_flight sync_state <> None;
      tree_head = Atomic.get tree_head_seen;
      unfollowed =
        Option.map
          (fun (s : stuck) ->
            ( s.n,
              match s.why with
                | `Undecodable why -> "it does not decode: " ^ why
                | `Version v -> Printf.sprintf "it is of version %d" v ))
          (Atomic.get stuck);
      failing = Atomic.get cycle_failing;
      damaged = damaged_paths ();
      stuck = List.length parked;
      retrying = List.length retrying;
      set_aside =
        Atomic.get staged_set_aside
        + List.length (Dqueue.Records.set_aside_records upload_log)
        + List.length (Dqueue.Records.set_aside_records intents);
      last_error =
        (match parked @ retrying with
          | (_, n) :: _ -> Some (Fail.to_string n.last)
          | [] -> None);
      uploading = List.filter_map upload_path (Dqueue.running uploads);
      bytes_owed =
        List.fold_left
          (fun acc (_, (e : Staged.edit)) ->
            if e.state = Owed then acc + e.size else acc)
          0 (Staged.edits staged);
      cache =
        (match Cache.last_counts cache with
          | Some c -> c
          | None -> Cache.enforce_cap cache);
      max_cache = Cache.cap cache;
    }

  let residency path =
    match resolve path with
      | Some (Published m) -> Cache.resident cache m
      | Some (Staged_edit _) -> (1, 1)
      | None -> Fail.absent "%s: no such file" path

  (* ponytail: polled; a per-key signal if the latency of a saved file's
     acknowledgement ever matters. *)
  let await_upload path =
    let failing () =
      List.exists
        (fun (id, _) -> upload_path id = Some path)
        (Dqueue.retrying uploads @ Dqueue.parked uploads)
    in
    let asked = ref false in
    (* Under the metadata lock: the commit drops the before-value and promotes
       the edit in one hold, and the caller reads the file after this. *)
    let committed () =
      with_meta (fun () ->
          match place_opt path with
            | None -> true
            | Some place -> Sync_state.before_file sync_state place = None)
    in
    let stopped () =
      Atomic.get cycle_failing <> None
      || Option.fold ~none:false
           ~some:(fun p -> cannot_commit (`File p))
           (place_opt path)
    in
    while
      (not (committed ()))
      && (not (Atomic.get paused))
      && (not (failing ()))
      && not (stopped ())
    do
      (match Staged.edit staged path with
        | Some { state = Uploaded _; _ } when not !asked ->
            asked := true;
            request_cycle ()
        | _ -> ());
      Stop.sleep 0.1
    done

  let hold_marker dir =
    Filename.concat (Mirror.path mirror dir) ".tsync-view-hold"

  let read_seconds path =
    Option.bind (Fs.read_file_opt path) (fun s ->
        Option.map (fun ms -> ms /. 1000.) (float_of_string_opt (String.trim s)))

  let pulled_at dir = read_seconds (pulled_marker dir)
  let view_hold dir = read_seconds (hold_marker dir)

  let hold_views dir ~until =
    let rec up dir =
      (match view_hold dir with
        | Some held when held >= until -> ()
        | _ ->
            if Fs.is_dir (Mirror.path mirror dir) then
              Fs.replace (hold_marker dir)
                (Printf.sprintf "%.0f" (until *. 1000.)));
      if dir <> "" then up (Names.parent_of dir)
    in
    up dir

  let pulling : (string, bool Rt.Promise.t) Hashtbl.t = Hashtbl.create 8
  let pulling_m = Mutex.create ()

  (* Concurrent pulls of one folder share one store read. *)
  let pull dir =
    let running, mine =
      Mutex.protect pulling_m (fun () ->
          match Hashtbl.find_opt pulling dir with
            | Some p -> (p, false)
            | None ->
                let p = Rt.Promise.create () in
                Hashtbl.replace pulling dir p;
                (p, true))
    in
    if mine then (
      let outcome = try Ok (pull_folder dir) with e -> Error e in
      Mutex.protect pulling_m (fun () -> Hashtbl.remove pulling dir);
      ignore (Rt.Promise.try_resolve_result running outcome));
    Rt.Promise.await running

  (* android §3.2 rule 3: a file's current version is its folder's view. *)
  let refresh_file path = ignore (pull (Names.parent_of path))

  type handle = Local_ops.handle

  let atomically = with_meta
  let folder_id path = Mirror.folder_id mirror path
  let path_of_id id = Mirror.key_of_id mirror id
  let parked () = Dqueue.parked uploads
  let rearm () = Dqueue.rearm uploads + Tsync_store.Composite.rearm C.composite
  let set_changed_hook f = changed_hook := f
  let uploads = uploads_running
end
