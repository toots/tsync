open Lwt.Syntax

type dest_stats = {
  name : string;
  checked : int;
  copied : int;
  copied_bytes : int;
}

module Make (C : Conf.S) = struct
  module Lk = Logical_key.Make (C)
  module Space = Chunk_space.Make (C)
  module L = Chunk_layout.Make (C)
  module Tree = Inode_tree.Make (C)

  (* What a destination holds, by key. A first resync of a shared bucket asks
     this of half a million objects, which on the heap is a string and a bucket
     apiece and is most of what a resync was ever holding. *)
  module Held = Hashtbl_mmap.Make (Hashtbl_mmap.String) (Hashtbl_mmap.Int)

  let spool_dir = Filename.concat C.cache_root "mirror"

  (* Bodies in memory: a copy holds a whole object, so this follows
     [max_chunk_buffers] rather than the file-level [max_uploads]. *)
  let copy_pool = Lwt_bounded.create ~name:"copy" ~max:C.max_chunk_buffers ()

  (* Round trips, which hold no body and so are not the same number: sizing a
     subtree is one HEAD an object and would otherwise queue behind a bound that
     stands for memory it does not use. *)
  let probe_max = max 8 (4 * C.max_chunk_buffers)
  let probe_pool = Lwt_bounded.create ~name:"probe" ~max:probe_max ()

  (* Objects a destination has in hand at once. A multiple of the wider bound,
     so both pools stay fed and [waiting] still means something, and a constant
     rather than the listing's length, which is the domain's. *)
  let entries_in_flight = 4 * probe_max

  (* Objects are content-addressed or immutable once written, so a size mismatch
     means the destination copy is corrupt. [None] when it was already correct;
     otherwise what was wrong with it, which is worth carrying to the caller. *)
  let sync_entry ?(on_start = fun () -> ()) ?held (module Src : Backend.S)
      (module Dst : Backend.S) (entry : Backend.file_entry) =
    let* size_there =
      match held with
        | Some held ->
            on_start ();
            Lwt.return (Held.find_opt held entry.key)
        | None ->
            (* Inside the slot, so the announcement tracks the bound: made as
               the entry is taken, it would name whatever the workers had
               reached ahead of the round trips. *)
            Lwt_bounded.use probe_pool (fun () ->
                on_start ();
                let+ h = Dst.head_opt ~key:entry.key () in
                Option.map (fun (h : Backend.file_entry) -> h.Backend.size) h)
    in
    let reason =
      match size_there with
        | None -> Some `Missing
        | Some size ->
            if Stored_key.is_dir_key entry.key then None
            else if size <> entry.size then Some `Wrong_size
            else None
    in
    match reason with
      | None -> Lwt.return_none
      | Some reason ->
          (* Taken here rather than around the whole entry, so the body budget is
             held only while a body exists. *)
          Lwt_bounded.use copy_pool (fun () ->
              if Stored_key.is_dir_key entry.key then
                let+ () = Dst.put ~key:entry.key ~data:Bigstring.empty () in
                Some (reason, 0)
              else
                let* data = Src.get ~key:entry.key () in
                let+ () = Dst.put ~key:entry.key ~data () in
                Some (reason, Bigstring.length data))

  let dedup_entries entries =
    (* Listing order is backend-dependent. *)
    List.sort_uniq
      (fun (a : Backend.file_entry) (b : Backend.file_entry) ->
        compare a.key b.key)
      entries

  let decode_entry body pos =
    let key = Listing.read_string body pos in
    let size = Int64.to_int (Listing.read_int64 body pos) in
    Backend.{ key; size; last_modified = 0.; etag = None }

  let record_entry (e : Backend.file_entry) =
    [
      (fun b -> Listing.str b e.Backend.key);
      (fun b -> Listing.int64 b (Int64.of_int e.Backend.size));
    ]

  (* What the listing came to, summed as it was written: the figure a caller
     plans against is wanted once, and the listing is on disk by the time
     anything could ask it a second time. *)
  let add_entry ~bytes listing (e : Backend.file_entry) =
    (* A folder index records the versions the store that built it reported,
       so a copy matches nothing where it lands; it is also a duplicate of every
       manifest body in its folder, which would transfer the namespace twice. *)
    if Stored_key.is_internal e.Backend.key then Lwt.return_unit
    else (
      bytes := Int64.add !bytes (Int64.of_int e.Backend.size);
      Listing.add listing (record_entry e))

  (* The chunk store is shared across domains on one bucket, and mirroring all of
     it is deliberate: chunks are content-addressed, so extra copies only help
     the other domains.

     That makes it the one prefix worth asking for a shard at a time: whole, it
     is the bucket's object count in one list, which is what a resync used to
     hold before it copied anything. *)
  let list_into ~listing ~bytes ~on_list ~name (module Src : Backend.S) prefix =
    on_list ~name:("listing " ^ name);
    let* entries = Src.list_prefix ~prefix () in
    Lwt_list.iter_s (add_entry ~bytes listing) entries

  (* A shard's listing holds no body, so it queues with the round trips.

     A batch at a time, and spilled before the next one is asked for: what a
     fan-out over every shard would hold is each shard's answer until the last
     of them arrives, which is the whole prefix again by another route. *)
  let list_chunks_into ~listing ~bytes ~on_list (module Src : Backend.S) =
    on_list ~name:"listing chunks";
    let width = Lwt_bounded.width probe_pool in
    let rec batch first =
      if first >= Chunk_layout.shards then Lwt.return_unit
      else
        let* per_shard =
          Lwt_bounded.map_with probe_pool
            (fun shard ->
              Src.list_prefix ~prefix:(C.chunk_prefix ^ shard ^ "/") ())
            (List.init
               (min width (Chunk_layout.shards - first))
               (fun k -> Chunk_layout.shard_name (first + k)))
        in
        let* () =
          Lwt_list.iter_s
            (fun entries -> Lwt_list.iter_s (add_entry ~bytes listing) entries)
            per_shard
        in
        batch (first + width)
    in
    batch 0

  let namespace_entries ~manifests_only ~on_list ~name src =
    let (module Src : Backend.S) = src in
    let* listing = Listing.create ~dir:spool_dir ~name ~decode:decode_entry in
    let bytes = ref 0L in
    let* () =
      list_into ~listing ~bytes ~on_list ~name:"manifests" src C.domain_prefix
    in
    let+ () =
      if manifests_only then Lwt.return_unit
      else
        let* () = list_chunks_into ~listing ~bytes ~on_list src in
        let* () =
          list_into ~listing ~bytes ~on_list ~name:"journal" src
            C.journal_prefix
        in
        let* () =
          list_into ~listing ~bytes ~on_list ~name:"versions" src
            C.versions_prefix
        in
        let* cursor = Src.head_opt ~key:C.cursor_key () in
        match cursor with
          | Some e -> add_entry ~bytes listing e
          | None -> Lwt.return_unit
    in
    (listing, !bytes)

  (* Where the source was enumerated by listing, the destination is too: a HEAD
     an object, against a namespace that answers a thousand keys a request, is
     the same question asked a thousand times over.

     A listing is a snapshot where a HEAD is fresh, which is the trade the
     source side already makes: a collection cannot be open while this runs, so
     what changes underneath is another client's write, and the next run copies
     it. *)
  let destination_view ~manifests_only ~on_list ~name dst =
    let* listing, _ =
      namespace_entries ~manifests_only ~on_list ~name:("dst-" ^ name) dst
    in
    let held = Held.create (Listing.count listing) in
    Lwt.finalize
      (fun () ->
        let+ () =
          Listing.iter listing (fun (e : Backend.file_entry) ->
              Held.replace held e.Backend.key e.Backend.size;
              Lwt.return_unit)
        in
        held)
      (fun () -> Listing.drop listing)

  (* [rel] itself and everything under it. *)
  let within ~rel path =
    rel = "" || path = rel || String.starts_with ~prefix:(rel ^ "/") path

  (* A folder [rel] sits inside: descended into, but nothing of its own is
     taken. *)
  let holds ~rel path = String.starts_with ~prefix:(path ^ "/") rel

  let chunk_keys (m : Manifest.t) =
    let table = m in
    List.init (Manifest.count table) (fun i -> L.key (Manifest.key table i))

  (* Only the folders [rel] runs through or lives in are descended into, so
     scoping to one folder costs its own subtree rather than the whole tree. A
     file brings the chunks it names: manifests alone would copy a listing the
     far side cannot read a byte of.

     Journal, versions and cursor are left out — they describe the domain, not
     this subtree, and copying part of a journal would state a history that never
     happened. *)
  let path_keys ~rel =
    let rec walk folder_id here acc =
      let* entries = Tree.children ~folder_id () in
      Lwt_list.fold_left_s
        (fun acc (entry : Inode_tree.entry) ->
          match entry.Inode_tree.body with
            | Inode_tree.Dir m ->
                let child = Logical_key.dir_in here m.Folder.name in
                let path = Logical_key.path child in
                if within ~rel path then
                  walk m.Folder.id child (entry.Inode_tree.bkey :: acc)
                else if holds ~rel path then walk m.Folder.id child acc
                else Lwt.return acc
            | Inode_tree.File m ->
                let path =
                  Logical_key.path
                    (Logical_key.file_in here (Manifest.recorded_name m))
                in
                if within ~rel path then
                  Lwt.return (chunk_keys m @ (entry.Inode_tree.bkey :: acc))
                else Lwt.return acc)
        acc entries
    in
    let+ keys = walk Stored_key.root_id Lk.root [] in
    List.sort_uniq compare keys

  (* This command copies a full backend onto a partial one, so an object the
     source cannot produce is the source being wrong, not the scope. *)
  let path_entries ~rel ~src_name ~on_list (module Src : Backend.S) =
    on_list ~name:(Printf.sprintf "walking the tree under %s" rel);
    let* keys = path_keys ~rel in
    on_list
      ~name:
        (Printf.sprintf "sizing %d object%s on %s" (List.length keys)
           (if List.length keys = 1 then "" else "s")
           src_name);
    let* entries =
      Lwt_bounded.map_with probe_pool
        (fun key ->
          let+ head = Src.head_opt ~key () in
          match head with
            | Some e -> e
            | None ->
                failwith
                  (Printf.sprintf "%s is missing from source %s" key src_name))
        keys
    in
    let* listing =
      Listing.create ~dir:spool_dir ~name:"src" ~decode:decode_entry
    in
    let bytes = ref 0L in
    let+ () =
      Lwt_list.iter_s (add_entry ~bytes listing) (dedup_entries entries)
    in
    (listing, !bytes)

  (* One call per object examined rather than one per object copied: what a run
     has behind it is the objects it found in place as much as the ones it
     moved, and a caller given only the copies cannot tell a mirror that is
     nearly done from one that has barely started. *)
  let resync_to ?(on_start = fun ~name:_ ~key:_ -> ())
      ?(on_entry = fun ~name:_ ~key:_ ~size:_ ~outcome:_ -> ()) ?held src dst
      ~name listing =
    let checked = ref 0 and copied = ref 0 and copied_bytes = ref 0 in
    let sync entry () =
      let key = entry.Backend.key in
      let size = entry.Backend.size in
      let+ outcome =
        sync_entry ~on_start:(fun () -> on_start ~name ~key) ?held src dst entry
      in
      match outcome with
        | None -> on_entry ~name ~key ~size ~outcome:`Present
        | Some (reason, bytes) ->
            on_entry ~name ~key ~size ~outcome:(`Copied (reason, bytes));
            incr copied;
            copied_bytes := !copied_bytes + bytes
    in
    (* A worker apiece and never more than there is work for, so the width is
       the code's and not the listing's. Each takes a probe slot and then a copy
       slot inside {!sync_entry}, one after the other, so nothing here holds a
       slot across the acquisition of another.

       The listing is read a record at a time out of its mapping, so the queue
       the workers pull from is pages rather than a list of the keyspace. *)
    let* cursor = Listing.read listing in
    let+ () =
      Lwt_bounded.each
        ~width:(min entries_in_flight (Listing.count listing))
        (fun () ->
          match Listing.next cursor with
            | None -> None
            | Some entry ->
                incr checked;
                Some (sync entry))
    in
    { name; checked = !checked; copied = !copied; copied_bytes = !copied_bytes }

  (* Copies between the stores themselves rather than through {!Conf.store}: the
     point is to reach the ones the composite writes off the caller's path, or
     does not write at all. Raises [Failure] when nothing has that name. *)
  let resync ?source ?(scope = `All) ?(on_scan = fun ~objects:_ ~bytes:_ -> ())
      ?(on_list = fun ~name:_ -> ()) ?on_start ?on_entry () =
    let named name =
      match
        List.filter
          (fun (m : Backend.member) -> m.Backend.name = name)
          C.members
      with
        | [m] -> m
        | [] ->
            failwith
              (Printf.sprintf "no backend named %s (available: %s)" name
                 (String.concat ", "
                    (List.map (fun (m : Backend.member) -> m.name) C.members)))
        | _ ->
            failwith
              (Printf.sprintf
                 "backend name %s is ambiguous; set distinct \"name\" fields \
                  in the config"
                 name)
    in
    let src =
      match (source, C.members) with
        | Some name, _ -> named name
        | None, m :: _ -> m
        | None, [] -> failwith "no backends configured"
    in
    (* A collection in progress leaves the chunk prefix holding only what has
       been marked so far, so listing it would copy a partial chunk set to every
       target and call it a resync. *)
    let* () =
      let* run = Space.read_run () in
      match (run, scope) with
        | None, _ | Some _, `Manifests -> Lwt.return_unit
        | Some r, (`All | `Path _) ->
            failwith
              (Printf.sprintf
                 "%s is being collected (%s, started %.0fs ago), so its chunks \
                  are only partly under the usual prefix. Let tsync gc finish, \
                  or stop it with tsync gc --abort, then resync."
                 C.domain_name
                 (Chunk_space.string_of_phase r.Chunk_space.phase)
                 (Unix.gettimeofday () -. r.Chunk_space.started))
    in
    let* () = Listing.reap ~dir:spool_dir in
    let* listing, bytes =
      match scope with
        | `All ->
            namespace_entries ~manifests_only:false ~on_list ~name:"src"
              src.backend
        | `Manifests ->
            namespace_entries ~manifests_only:true ~on_list ~name:"src"
              src.backend
        | `Path rel ->
            path_entries ~rel ~src_name:src.name ~on_list src.Backend.backend
    in
    on_scan ~objects:(Listing.count listing) ~bytes;
    (* A path scope names its objects one at a time on the source too, so there
       is no listing to be symmetric with and the HEAD stays. *)
    let listed_scope =
      match scope with
        | `All -> Some false
        | `Manifests -> Some true
        | `Path _ -> None
    in
    Lwt.finalize
      (fun () ->
        C.members
        |> List.filter (fun (m : Backend.member) -> m.Backend.name <> src.name)
        |> Lwt_list.map_s (fun (m : Backend.member) ->
            let* held =
              match listed_scope with
                | None -> Lwt.return_none
                | Some manifests_only ->
                    let+ held =
                      destination_view ~manifests_only ~name:m.Backend.name
                        ~on_list:(fun ~name ->
                          on_list ~name:(name ^ " on " ^ m.Backend.name))
                        m.Backend.backend
                    in
                    Some held
            in
            resync_to ?on_start ?on_entry ?held src.Backend.backend
              m.Backend.backend ~name:m.Backend.name listing))
      (fun () -> Listing.drop listing)
end
