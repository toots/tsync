open Tsync_core
open Tsync_store

type main = {
  member : Composite.member;
  root : string;
  spaces : Chunk_spaces.t;
  tells : Composite.member list;
}

type failure = Unsupported of string | Busy

type outcome =
  | Completed
  | Suspended of { phase : Gc_record.phase; cursor : string }
  | Halted of string

type stats = {
  main : string;
  outcome : outcome;
  roots_marked : int;
  chunks_promoted : int;
  chunks_verified : int;
  chunks_corrupt : int;
  chunks_unreadable : int;
  chunks_cleared : int;
  chunks_reclaimed : int;
  bytes_reclaimed : int;
}

type survey = {
  surveyed : string;
  run : (Gc_record.phase * string) option;
  run_unreadable : bool;
  chunks_referenced : int;
  chunks_reclaimable : int;
  bytes_reclaimable : int;
  chunks_missing : Chunk_key.t list;
  per_copy : (string * int) list;
  chunks_corrupt : int;
}

let delete_batch = 1000

exception Halt of string

(* gc.md §5.2: every collectable main is collected; the first tells copies. *)
let targets composite =
  let members = Composite.members composite in
  let copies =
    List.filter
      (fun (m : Composite.member) ->
        m.role = Composite.Replica || m.role = Backfill)
      members
  in
  List.filter_map
    (fun (m : Composite.member) ->
      match (m.role, Chunk_spaces.of_store m.store) with
        | Composite.Main, Some spaces ->
            Some
              {
                member = m;
                root = Chunk_spaces.root spaces;
                spaces;
                tells = [];
              }
        | _ -> None)
    members
  |> List.mapi (fun i m -> if i = 0 then { m with tells = copies } else m)

let dir m p =
  let p = Key.prefix_to_string p in
  Filename.concat m.root (String.sub p 0 (String.length p - 1))

let surviving m d = dir m (Key.chunks d)
let outgoing m d = dir m (Key.chunks_from d)

let entries path =
  match Fs.readdir_opt path with
    | Some l -> List.filter (fun n -> not (Names.is_temp_name n)) l
    | None -> []

let shards path = List.filter Names.valid_shard (entries path)

let subdirs path =
  List.filter (fun n -> Fs.is_dir (Filename.concat path n)) (entries path)

(* A missing manifest area must never read as "no references" (§5.5). *)
let enumerate m d ~after =
  let manifests = dir m (Key.manifests d) in
  if (not (Fs.is_dir manifests)) && shards (outgoing m d) <> [] then
    raise
      (Halt "the manifest area is missing while the outgoing space holds chunks");
  Gc_plan.namespaces ~manifests:(subdirs manifests)
    ~versions:(subdirs (dir m (Key.versions d)))
    ~after

let references key body =
  match Chunk_spaces.references key body with
    | Ok cs -> cs
    | Error reason -> raise (Halt reason)

(* Every chunk the namespace's children name; a child listed but gone names
   nothing, since a rename's copy went through the gate. *)
let namespace_references m d ns =
  let store = m.member.store in
  List.concat_map
    (fun (e : Store.entry) ->
      if Key.is_internal_leaf (Key.leaf e.key) then []
      else (
        match store.get_opt e.key with
          | None -> []
          | Some body -> references e.key body))
    (store.list_prefix (Gc_plan.namespace_prefix d ns))

type counters = {
  mutable marked : int;
  mutable promoted : int;
  mutable verified : int;
  mutable corrupt : int;
  mutable unreadable : int;
  mutable cleared : int;
  mutable reclaimed : int;
  mutable bytes : int;
}

let counters () =
  {
    marked = 0;
    promoted = 0;
    verified = 0;
    corrupt = 0;
    unreadable = 0;
    cleared = 0;
    reclaimed = 0;
    bytes = 0;
  }

(* §5.5: reads the collected main alone, files or clears the marker, never
   discards the chunk. *)
let verify_promoted m d n c =
  let store = m.member.store in
  let marker = Key.marker d c in
  n.verified <- n.verified + 1;
  match store.get_opt (Key.chunk d c) with
    | Some b when Chunk_key.equal (Chunk_key.of_bigstring b) c ->
        if store.delete marker then n.cleared <- n.cleared + 1
    | Some b ->
        n.corrupt <- n.corrupt + 1;
        store.put marker
          (Bigstring.of_string
             (Corruption_marker.body
                ~computed:(Chunk_key.to_string (Chunk_key.of_bigstring b))
                (Some (Bigstring.length b))))
    | None ->
        n.unreadable <- n.unreadable + 1;
        store.put marker
          (Bigstring.of_string
             (Corruption_marker.body ~reason:"unreadable while verifying" None))

let mark m d n ~verify ns =
  let cs = List.sort_uniq Chunk_key.compare (namespace_references m d ns) in
  let moved = List.filter (Chunk_spaces.promote m.spaces d) cs in
  Chunk_spaces.sync_shards m.spaces d moved;
  n.promoted <- n.promoted + List.length moved;
  if verify then List.iter (verify_promoted m d n) moved;
  n.marked <- n.marked + 1

let rec batches l =
  if List.length l <= delete_batch then [l]
  else
    List.filteri (fun i _ -> i < delete_batch) l
    :: batches (List.filteri (fun i _ -> i >= delete_batch) l)

let file_size path =
  match Fs.lstat_opt path with Some st -> Int64.to_int st.st_size | None -> 0

(* The doom step (§5.5): copies are owed the keys durably before the outgoing
   entries are unlinked, all under the exclusive publish lock. *)
let close m d n composite ~run ~generation shard =
  let fdir = Filename.concat (outgoing m d) shard in
  Chunk_spaces.with_publish_lock m.spaces d ~exclusive:true (fun () ->
      let names = entries fdir in
      let doomed =
        Gc_plan.doomed ~shard ~names
          ~in_surviving:(Chunk_spaces.in_surviving m.spaces d)
      in
      let keys = List.map (Key.chunk d) doomed in
      if keys <> [] then
        List.iter
          (fun copy ->
            List.iter
              (fun keys ->
                Composite.submit_collection_delete composite copy ~keys ~run
                  ~shard ~generation)
              (batches keys))
          m.tells;
      m.member.store.delete_multi (List.map (Key.marker d) doomed);
      List.iter
        (fun c ->
          n.bytes <-
            n.bytes + file_size (Filename.concat fdir (Chunk_key.to_string c)))
        doomed;
      n.reclaimed <- n.reclaimed + List.length doomed;
      List.iter (fun name -> Fs.unlink_quiet (Filename.concat fdir name)) names;
      Fs.rm_rf fdir)

let rename_quiet src dst =
  match Fs.eintr (fun () -> Unix.rename src dst) with
    | () -> true
    | exception Unix.Unix_error _ -> false

let move_across fdir sdir =
  Fs.mkdir_p ~perm:0o755 sdir;
  List.iter
    (fun name ->
      let s = Filename.concat sdir name in
      if not (Fs.exists s) then
        ignore (rename_quiet (Filename.concat fdir name) s))
    (entries fdir);
  Fs.fsync_dir sdir

(* §5.5 keep_one: names in both spaces are identical bytes (A2), so either copy
   may be dropped. *)
let keep_one m d shard =
  let fdir = Filename.concat (outgoing m d) shard
  and sdir = Filename.concat (surviving m d) shard in
  let s_names = entries sdir in
  (match
     Gc_plan.keep_plan ~surviving:(List.length s_names)
       ~outgoing:(List.length (entries fdir))
   with
    | Rename_shard ->
        if Fs.is_dir sdir then (
          try Unix.rmdir sdir with Unix.Unix_error _ -> ());
        Fs.mkdir_p ~perm:0o755 (surviving m d);
        if not (rename_quiet fdir sdir) then move_across fdir sdir
    | Push_down ->
        List.iter
          (fun name ->
            ignore
              (rename_quiet
                 (Filename.concat sdir name)
                 (Filename.concat fdir name)))
          s_names;
        let pushed =
          (try
             Unix.rmdir sdir;
             true
           with Unix.Unix_error _ -> false)
          && rename_quiet fdir sdir
        in
        if not pushed then move_across fdir sdir
    | Move_across -> move_across fdir sdir);
  Fs.fsync_dir (surviving m d);
  Fs.rm_rf fdir

let record m d r = Gc_record.write m.member.store d r
let generation m d = Gc_generation.read m.member.store d

let settle m d composite =
  Gc_generation.settle m.member.store d ~owed:(fun g ->
      Composite.collection_owed composite ~generation:g)

(* One session on one main, under its run lock (§5.5). *)
let session ?budget ?pause ~verify ~keep composite d m =
  let n = counters () in
  let deadline = Option.map (fun b -> Rt.now () +. b) budget in
  let over () = match deadline with Some t -> Rt.now () > t | None -> false in
  let between () =
    Stop.check ();
    Option.iter Rt.sleep pause
  in
  let r0 = Gc_record.read m.member.store d in
  let started =
    match r0 with Record r -> r.started | _ -> Unix.gettimeofday ()
  in
  (* At least one unit per session, so a zero budget steps. *)
  let rec units phase ~write todo =
    match todo with
      | [] -> None
      | u :: rest ->
          write u;
          if rest <> [] && over () then Some (Suspended { phase; cursor = u })
          else (
            between ();
            units phase ~write rest)
  in
  let rec abandon cursor =
    let todo = Gc_plan.after ~cursor (shards (outgoing m d)) in
    match
      units Abandoning
        ~write:(fun shard ->
          keep_one m d shard;
          record m d
            { phase = Abandoning; started; cursor = shard; generation = None })
        todo
    with
      | Some s -> s
      | None ->
          if shards (outgoing m d) <> [] then abandon ""
          else (
            Fs.rm_rf (outgoing m d);
            Gc_record.clear m.member.store d;
            Completed)
  in
  let finish () =
    Fs.rm_rf (outgoing m d);
    Gc_record.clear m.member.store d;
    settle m d composite;
    Completed
  in
  let close_from ~after g =
    let run = Key.run_name started in
    let all =
      List.sort_uniq String.compare
        (shards (surviving m d) @ shards (outgoing m d))
    in
    match
      units Closing
        ~write:(fun shard ->
          if Fs.is_dir (Filename.concat (outgoing m d) shard) then
            close m d n composite ~run ~generation:g shard;
          record m d
            { phase = Closing; started; cursor = shard; generation = Some g })
        (Gc_plan.after ~cursor:after all)
    with
      | Some s -> s
      | None -> finish ()
  in
  let fresh_generation () =
    match Gc_plan.closing_generation (generation m d) with
      | Error e -> raise (Halt e)
      | Ok g ->
          if generation m d <> Some g then
            Gc_generation.write m.member.store d g;
          g
  in
  let rec wait_settled () =
    match generation m d with
      | Some g
        when g mod 2 = 1
             && Composite.collection_owed composite ~generation:g > 0 ->
          if over () then false
          else (
            Rt.sleep 5.;
            wait_settled ())
      | _ -> true
  in
  let outcome =
    try
      match Gc_plan.start ~r0 ~keep with
        | Resume_keep cursor -> abandon cursor
        | Begin_keep ->
            record m d
              { phase = Abandoning; started; cursor = ""; generation = None };
            abandon ""
        | Resume_close { after; generation = Some g } -> close_from ~after g
        | Resume_close { after; generation = None } ->
            let g = fresh_generation () in
            record m d
              { phase = Closing; started; cursor = after; generation = Some g };
            close_from ~after g
        | Open { after; _ } -> (
            Chunk_spaces.with_publish_lock m.spaces d ~exclusive:true (fun () ->
                record m d
                  {
                    phase = Opening;
                    started;
                    cursor = after;
                    generation = None;
                  };
                if not (Fs.exists (outgoing m d)) then
                  ignore (rename_quiet (surviving m d) (outgoing m d)));
            let todo = enumerate m d ~after in
            record m d
              { phase = Marking; started; cursor = after; generation = None };
            match
              units Marking
                ~write:(fun ns ->
                  mark m d n ~verify ns;
                  record m d
                    { phase = Marking; started; cursor = ns; generation = None })
                todo
            with
              | Some s -> s
              | None ->
                  if not (wait_settled ()) then
                    Suspended { phase = Marking; cursor = "" }
                  else (
                    let g = fresh_generation () in
                    record m d
                      {
                        phase = Closing;
                        started;
                        cursor = "";
                        generation = Some g;
                      };
                    close_from ~after:"" g))
    with Halt reason -> Halted reason
  in
  {
    main = m.member.name;
    outcome;
    roots_marked = n.marked;
    chunks_promoted = n.promoted;
    chunks_verified = n.verified;
    chunks_corrupt = n.corrupt;
    chunks_unreadable = n.unreadable;
    chunks_cleared = n.cleared;
    chunks_reclaimed = n.reclaimed;
    bytes_reclaimed = n.bytes;
  }

let each composite f =
  match targets composite with
    | [] ->
        Error
          (Unsupported
             "no main of this domain is a filesystem store local to this host")
    | ms ->
        let rec go acc = function
          | [] -> Ok (List.rev acc)
          | m :: rest -> (
              match
                Chunk_spaces.with_run_lock m.spaces (Composite.domain composite)
                  (fun () -> f m)
              with
                | Ok v -> go (v :: acc) rest
                | Error `Busy -> Error Busy)
        in
        go [] ms

type status = {
  collected : string;
  record : Gc_record.read;
  generation : int option;
  owed : int;
}

(* Reads only: no lock, so it answers while a session runs. *)
let status composite =
  let d = Composite.domain composite in
  List.map
    (fun m ->
      let generation = Gc_generation.read m.member.store d in
      {
        collected = m.member.name;
        record = Gc_record.read m.member.store d;
        generation;
        owed =
          (match generation with
            | Some g when g mod 2 = 1 ->
                Composite.collection_owed composite ~generation:g
            | _ -> 0);
      })
    (targets composite)

(* gc §5.7: a remote copy is told by requests, so it needs a function this
   owner confirmed; deleting there one request per chunk is refused. *)
let direct_deletes_refused composite =
  match targets composite with
    | m :: _ ->
        List.filter
          (fun (c : Composite.member) ->
            c.store.local_path = None
            && not (Composite.function_confirmed composite c))
          m.tells
    | [] -> []

let run ?budget ?pause ?(verify = false) ?(keep = false) composite =
  let d = Composite.domain composite in
  match direct_deletes_refused composite with
    | _ :: _ as copies when not keep ->
        Error
          (Unsupported
             (Printf.sprintf
                "%s: a remote copy without a confirmed bucket function would \
                 be sent one delete request per chunk (gc --probe)"
                (String.concat ", "
                   (List.map (fun (c : Composite.member) -> c.name) copies))))
    | _ -> each composite (session ?budget ?pause ~verify ~keep composite d)

(* §5.9 on a main of millions of chunks: one table of referenced chunks, each
   flagged once a shard listing shows it, and the chunk area read one shard at
   a time. *)
let survey_one ~verify d m =
  let referenced : (Chunk_key.t, bool) Hashtbl.t = Hashtbl.create 65536 in
  let corrupt = ref 0 in
  let run, run_unreadable =
    match Gc_record.read m.member.store d with
      | Record r -> (Some (r.phase, r.cursor), false)
      | Unreadable -> (None, true)
      | Absent -> (None, false)
  in
  match
    List.iter
      (fun ns ->
        List.iter
          (fun c -> Hashtbl.replace referenced c false)
          (namespace_references m d ns))
      (enumerate m d ~after:"")
  with
    | exception Halt reason -> Error reason
    | () ->
        let reclaimable = ref 0 and bytes = ref 0 in
        List.iter
          (fun shard ->
            let listing =
              m.member.store.list_prefix (Key.shard_prefix d shard)
            in
            let s =
              Gc_plan.unreferenced ~referenced:(Hashtbl.mem referenced) listing
            in
            reclaimable := !reclaimable + s.reclaimable;
            bytes := !bytes + s.bytes;
            List.iter
              (fun (e : Store.entry) ->
                match Key.chunk_of e.key with
                  | Some c when Hashtbl.mem referenced c ->
                      Hashtbl.replace referenced c true;
                      if verify then (
                        match m.member.store.get_opt e.key with
                          | Some b
                            when Chunk_key.equal (Chunk_key.of_bigstring b) c ->
                              ()
                          | _ -> incr corrupt)
                  | _ -> ())
              listing)
          (List.init 4096 (Printf.sprintf "%03x"));
        let missing =
          Hashtbl.fold
            (fun c seen acc -> if seen then acc else c :: acc)
            referenced []
          |> List.sort Chunk_key.compare
        in
        Ok
          {
            surveyed = m.member.name;
            run;
            run_unreadable;
            chunks_referenced = Hashtbl.length referenced;
            chunks_reclaimable = !reclaimable;
            bytes_reclaimable = !bytes;
            chunks_missing = missing;
            per_copy =
              List.map
                (fun (c : Composite.member) -> (c.name, !reclaimable))
                m.tells;
            chunks_corrupt = !corrupt;
          }

let dry_run ?(verify = false) composite =
  let d = Composite.domain composite in
  each composite (survey_one ~verify d)
