open Tsync_core
open Tsync_store

type source =
  | Stored of Chunk_key.t
  | Bytes of Bigstring.t
  | Lazy of (unit -> Bigstring.t)

exception Source_changed of string

let snapshot_deadline = 10.
let corruption_ttl = 5.

module Make (C : Context.S) = struct
  let d = C.domain
  let store = C.store
  let buffers = Rt.Semaphore.create ~name:"chunk-buffers" C.max_chunk_buffers
  let downloads = Rt.Semaphore.create ~name:"downloads" C.max_downloads
  let resolved_chunk_size = Atomic.make None

  (* 01 §3.5: configured, else the main's recommendation within range, else
     the default. *)
  let chunk_size () =
    match C.chunk_size_config with
      | Some cs -> cs
      | None -> (
          match Atomic.get resolved_chunk_size with
            | Some cs -> cs
            | None ->
                let cs =
                  match
                    (store.capabilities (Key.domain_prefix d)).chunk_size
                  with
                    | Some cs
                      when cs >= Chunking.chunk_size_min
                           && cs <= Chunking.chunk_size_max ->
                        cs
                    | Some cs ->
                        Log.warn
                          "ignoring the store's recommended chunk size %d, out \
                           of range"
                          cs;
                        Chunking.default_chunk_size
                    | None -> Chunking.default_chunk_size
                in
                Atomic.set resolved_chunk_size (Some cs);
                cs)

  let marked_m = Mutex.create ()
  let marked : (string, unit) Hashtbl.t = Hashtbl.create 16
  let marked_at = ref neg_infinity

  let verifying_members () =
    List.filter
      (fun (m : Composite.member) ->
        m.role <> Composite.Backfill
        &&
          try (m.store.capabilities (Key.domain_prefix d)).verified
          with _ -> false)
      (Composite.members C.composite)

  (* 02 §4.7: a failed listing counts as nothing marked for that member, and is
     reported. *)
  let refresh_marked () =
    let found = Hashtbl.create 16 in
    List.iter
      (fun (m : Composite.member) ->
        match m.store.list_prefix (Key.corrupted d) with
          | l ->
              List.iter
                (fun (e : Store.entry) ->
                  Option.iter
                    (fun (_, c) ->
                      Hashtbl.replace found (Chunk_key.to_string c) ())
                    (Key.chunk_of_marker e.key))
                l
          | exception e ->
              Log.once
                ("corruption-list:" ^ m.name)
                Warn "cannot list corruption markers on %s: %s" m.name
                (Printexc.to_string e))
      (verifying_members ());
    Mutex.protect marked_m (fun () ->
        Hashtbl.reset marked;
        Hashtbl.iter (fun k () -> Hashtbl.replace marked k ()) found;
        marked_at := Rt.now ())

  let is_marked ck =
    if
      Mutex.protect marked_m (fun () ->
          Rt.now () -. !marked_at > corruption_ttl)
    then refresh_marked ();
    Mutex.protect marked_m (fun () ->
        Hashtbl.mem marked (Chunk_key.to_string ck))

  let forget_marked ck =
    Mutex.protect marked_m (fun () ->
        Hashtbl.remove marked (Chunk_key.to_string ck))

  let memo_m = Mutex.create ()
  let memo : (string, unit) Hashtbl.t = Hashtbl.create 4096

  let remembered ck =
    Mutex.protect memo_m (fun () -> Hashtbl.mem memo (Chunk_key.to_string ck))

  let remember ck =
    Mutex.protect memo_m (fun () ->
        Hashtbl.replace memo (Chunk_key.to_string ck) ())

  let drop_memo cks =
    Mutex.protect memo_m (fun () ->
        List.iter (fun ck -> Hashtbl.remove memo (Chunk_key.to_string ck)) cks)

  let present ck = store.head_opt (Key.chunk d ck) <> None

  (* 02 §4.1: a marked chunk is never deduplicated against; the memo only
     spares a presence check. *)
  let known ck = (not (is_marked ck)) && (remembered ck || present ck)

  let put_chunk ck body =
    store.put (Key.chunk d ck) body;
    forget_marked ck;
    remember ck

  let get_chunk ck =
    Rt.Semaphore.with_slot downloads (fun () ->
        match store.get_opt (Key.chunk d ck) with
          | Some b -> b
          | None ->
              Fail.corrupt "chunk %s is on no store" (Chunk_key.to_string ck))

  let get_verified_chunk ck =
    let check b = Chunk_key.equal (Chunk_key.of_bigstring b) ck in
    let b = get_chunk ck in
    if check b then b
    else (
      let b = get_chunk ck in
      if check b then b
      else
        Fail.corrupt "chunk %s does not hash to its key after two reads"
          (Chunk_key.to_string ck))

  let get_chunk_range ck off len =
    Rt.Semaphore.with_slot downloads (fun () ->
        match store.get_range (Key.chunk d ck) off len with
          | Some b -> b
          | None ->
              Fail.corrupt "chunk %s is on no store" (Chunk_key.to_string ck))

  let chunk_bytes = function
    | Stored _ -> None
    | Bytes b -> Some b
    | Lazy f -> Some (f ())

  (* Chunks only: every chunk the manifest names is on the store when this
     returns. *)
  let upload_chunks ?(cancel = Atomic.make false) ?(progress = fun _ -> ())
      ?(sent = fun _ -> ()) ~name ~size ~chunk_size ~mtime source =
    let count = Chunking.manifest_count ~size ~cs:chunk_size in
    let one i =
      if Atomic.get cancel then raise Rt.Cancelled;
      Stop.check ();
      match source i with
        | Stored k -> k
        | src ->
            Rt.Semaphore.with_slot buffers (fun () ->
                let b = Option.get (chunk_bytes src) in
                let expected =
                  if size = 0 then 0 else Chunking.length ~size ~cs:chunk_size i
                in
                if Bigstring.length b <> expected then
                  raise (Source_changed name);
                let ck = Chunk_key.of_bigstring b in
                if not (known ck) then (
                  put_chunk ck b;
                  sent (Bigstring.length b));
                progress (Bigstring.length b);
                ck)
    in
    let keys = Rt.map_bounded ~width:2 one (List.init count Fun.id) in
    Manifest.make ~name ~size ~mtime ~chunk_size keys

  let slot parent leaf = Key.child d parent leaf

  let get_slot parent leaf =
    Option.map Bigstring.to_string (store.get_opt (slot parent leaf))

  let head_slot parent leaf = store.head_opt (slot parent leaf)

  let group_of key =
    let rel = Key.rel (Key.manifests d) key in
    rel

  let version_m = Mutex.create ()
  let last_version : (string, int64) Hashtbl.t = Hashtbl.create 64

  let next_version_ts group =
    Mutex.protect version_m (fun () ->
        let now = Int64.of_float (Unix.gettimeofday () *. 1e9) in
        let ts =
          match Hashtbl.find_opt last_version group with
            | Some l when now <= l -> Int64.succ l
            | _ -> now
        in
        Hashtbl.replace last_version group ts;
        ts)

  (* Best effort within [snapshot_deadline]: a failed snapshot is logged and
     never blocks the write. *)
  let save_version key =
    if C.versioning then (
      try
        Rt.with_timeout snapshot_deadline (fun () ->
            match store.get_opt key with
              | Some body when Manifest.is_manifest body ->
                  let group = group_of key in
                  store.put
                    (Key.version d ~group ~ns:(next_version_ts group))
                    body
              | _ -> ())
      with
        | (Stop.Stopping | Rt.Cancelled) as e -> raise e
        | e ->
            Log.warn "could not save a version of %s: %s" (Key.to_string key)
              (Printexc.to_string e))

  let missing_of = function
    | Fail.E { kind = Missing_chunks l; _ } ->
        Some (List.filter_map Chunk_key.of_string l)
    | _ -> None

  (* 02 §4.1 step 3: on a "missing chunks" refusal the named chunks are dropped
     from the memo, re-sent from [resend], and the put is retried. *)
  let put_manifest ?(resend = fun _ -> None) ?(save = true) key (m : Manifest.t)
      =
    if save then save_version key;
    let rec attempt n =
      match store.put key (Bigstring.of_string m.body) with
        | () -> ()
        | exception e -> (
            match missing_of e with
              | Some cks when n < 2 ->
                  drop_memo cks;
                  List.iter
                    (fun ck ->
                      match resend ck with
                        | Some b -> put_chunk ck b
                        | None -> raise e)
                    cks;
                  attempt (n + 1)
              | _ -> raise e)
    in
    attempt 0

  let publish ?resend ~parent ~leaf (m : Manifest.t) =
    put_manifest ?resend (slot parent leaf) (Manifest.rename m leaf)

  let delete_slot parent leaf =
    let key = slot parent leaf in
    save_version key;
    store.delete key

  (* 02 §4.4: snapshot, server-side copy (gated), delete the source, then re-put
     with the new leaf recorded. *)
  let rename_file ~src:(sp, sl) ~dst:(dp, dl) =
    let skey = slot sp sl and dkey = slot dp dl in
    save_version skey;
    save_version dkey;
    store.copy skey dkey;
    ignore (store.delete skey);
    match store.get_opt dkey with
      | Some b -> (
          match Manifest.of_body b with
            | Some m when m.name <> dl ->
                put_manifest ~save:false dkey (Manifest.rename m dl)
            | _ -> ())
      | None -> ()

  let list_versions parent leaf =
    let group = group_of (slot parent leaf) in
    List.filter_map
      (fun (e : Store.entry) ->
        let _, ts = Key.split_last (Key.to_string e.key) in
        Option.map (fun ns -> (ns, e)) (Int64.of_string_opt ts))
      (store.list_prefix
         (Key.as_prefix (Key.v (Key.prefix_to_string (Key.versions d) ^ group))))
    |> List.sort (fun (a, _) (b, _) -> compare b a)

  let get_version (e : Store.entry) =
    Bigstring.to_string (Store.get store e.key)

  let revert ~parent ~leaf (version : Store.entry) =
    let body = get_version version in
    match Manifest.decode body with
      | Some m -> put_manifest (slot parent leaf) (Manifest.rename m leaf)
      | None ->
          Fail.corrupt "version %s is not a manifest"
            (Key.to_string version.key)
end
