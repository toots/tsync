(* File content as bytes, served per cache chunk out of {!Chunk_cache}.

   A file is never assembled: a read maps its byte range onto the stored chunks
   backing it and fetches what is absent, the store answering "is it local?" by
   the body existing. *)

open Lwt.Syntax

(* Read-ahead applies to sequential reads only. *)
let readahead_bytes = 4 * 1024 * 1024
let max_readahead_groups = 8

module Make (C : Conf.S) (R : Remote.S) = struct
  module Cc = Chunk_cache.Make (C) (R)
  module Mf = Manifest.Make (C)

  (* Advisory: a lost or stale entry costs at most one un-prefetched read. *)
  let last_read_end : (string, int) Hashtbl.t = Hashtbl.create 64

  (* Files waiting on the network because something is reading them. Separate
     from [active] below, which tracks whole-file materialization: that has a
     total known up front and a scoped lifetime, and a demand read has neither.

     A materialization's reads do not land here on their own: it fetches every
     group first, so by the time [pread] runs the chunks are local and report no
     backend. {!fetch_groups} credits it instead, at the one point where it does
     touch the network -- otherwise a fetch started from Finder, which is the
     whole of what the macOS frontend does, shows in the tray as a count with no
     rows under it. *)
  type pull = {
    size : int;
    started : float;
    mutable bytes : int;
    mutable last : float;
    (* Measured over a window rather than since the start, so a stall shows as
       the rate falling rather than as an average that takes as long to decay as
       it took to build. *)
    mutable mark_at : float;
    mutable mark_bytes : int;
    mutable rate : float;
  }

  let rate_window = 2.
  let pulls : (string, pull) Hashtbl.t = Hashtbl.create 8

  (* Longer than the tray's poll interval, or a row blinks out between two polls
     that both saw traffic. *)
  let pull_idle = 8.

  (* A cold `grep -r' over a large tree touches every file in it. Without a cap
     the table grows for the life of the process whether or not anyone is
     watching. *)
  let max_pulling = 256

  let prune_pulls now =
    Hashtbl.filter_map_inplace
      (fun _ p ->
        let idle = now -. p.last in
        (* A negative idle is the clock having stepped, not a fresh entry.
           Expiring it beats letting a row sit there until the daemon restarts. *)
        if idle > pull_idle || idle < 0. then None else Some p)
      pulls

  (* Synchronous, and called with no await between the lookup and the update:
     every writer runs on the Lwt loop (FUSE workers reach it through
     [Lwt_preemptive.run_in_main]), so that is all the mutual exclusion this
     needs. *)
  let credit_pull key ~size n =
    let now = Unix.gettimeofday () in
    match Hashtbl.find_opt pulls key with
      | Some p ->
          p.bytes <- p.bytes + n;
          p.last <- now;
          let elapsed = now -. p.mark_at in
          if elapsed >= rate_window then (
            p.rate <- float_of_int (p.bytes - p.mark_bytes) /. elapsed;
            p.mark_at <- now;
            p.mark_bytes <- p.bytes)
      | None ->
          if Hashtbl.length pulls >= max_pulling then prune_pulls now;
          Hashtbl.replace pulls key
            {
              size;
              started = now;
              bytes = n;
              last = now;
              mark_at = now;
              mark_bytes = 0;
              rate = 0.;
            }

  type pulling = {
    key : string;
    bytes : int;
    size : int;
    seconds : float;
    rate : float;
  }

  (* [status] asks on every tray poll, so the answer is bounded. Biggest first,
     so what is cut is what mattered least. *)
  let max_reported = 16

  let pulling_now ?now () =
    let now = match now with Some t -> t | None -> Unix.gettimeofday () in
    prune_pulls now;
    Hashtbl.fold
      (fun key (p : pull) acc ->
        {
          key;
          bytes = p.bytes;
          size = p.size;
          (* Guarded for the same clock step [prune_pulls] guards against. *)
          seconds = Float.max 0. (now -. p.started);
          (* Nothing measured yet, so the average stands in rather than a zero
             that would read as a stall. *)
          rate =
            (if p.rate > 0. then p.rate
             else (
               let elapsed = Float.max 0. (now -. p.started) in
               if elapsed > 0. then float_of_int p.bytes /. elapsed else 0.));
        }
        :: acc)
      pulls []
    |> List.sort (fun a b -> compare b.bytes a.bytes)
    |> List.filteri (fun i _ -> i < max_reported)

  let cache_chunk_size = Conf.cache_chunk_size (module C)

  (* Reuses [cached] while [i] stays in the same group, so a sequential read
     rebuilds one group per boundary crossing rather than one per chunk. *)
  let group_at ~table ~per ~cached i =
    let gi = Chunk_group.index_of ~per i in
    match cached with
      | Some (j, g) when j = gi -> Some (gi, g)
      | _ -> Option.map (fun g -> (gi, g)) (Chunk_group.of_table ~table ~per i)

  (* Credits {!pulls} as a foreground read does: prefetch is what pulls the bytes
     during sequential streaming, so leaving it out would empty the display
     exactly when a large file is downloading well. *)
  let read_ahead ~id ~size ~table ~per ~chunk_size ~last =
    let n = Chunk_table.count table in
    let window =
      min max_readahead_groups
        (max 1 (readahead_bytes / max 1 (per * max 1 chunk_size)))
    in
    let first = (Chunk_group.index_of ~per last + 1) * per in
    let hi = min (n - 1) (first + (window * per) - 1) in
    if first <= hi then
      Lwt.async (fun () ->
          Lwt.catch
            (fun () ->
              let rec go i =
                if i > hi then Lwt.return_unit
                else
                  let* () =
                    match Chunk_group.of_table ~table ~per i with
                      | Some group ->
                          let+ fetched = Cc.ensure_fetched ~group () in
                          if fetched then
                            credit_pull id ~size (Chunk_group.bytes group)
                      | None -> Lwt.return_unit
                  in
                  go (i + per)
              in
              go first)
            (fun _ -> Lwt.return_unit))

  (* [id] names the file for the read-ahead heuristic and for {!pulling}, which
     is how a byte fetched here is attributed to the file someone is reading. *)
  let pread ~id ~(manifest : Manifest.t) buf ~offset =
    let cs = manifest.Manifest.chunk_size in
    let size = manifest.Manifest.size in
    let want = Bigarray.Array1.dim buf in
    let start = Int64.to_int offset in
    let avail = Int64.to_int (Int64.sub size offset) in
    let total = min want (max 0 avail) in
    let table = manifest.Manifest.chunks in
    let n = Chunk_table.count table in
    if total <= 0 || cs <= 0 || n = 0 then Lwt.return 0
    else (
      let per = Mf.per manifest in
      let rec go pos done_ cached =
        if done_ >= total then Lwt.return done_
        else (
          let i = pos / cs in
          if i >= n then Lwt.return done_
          else (
            let chunk_off = pos mod cs in
            let take = min (cs - chunk_off) (total - done_) in
            match group_at ~table ~per ~cached i with
              | None ->
                  Lwt.fail
                    (Backend.Backend_error
                       (Printf.sprintf "manifest %s: missing chunk %d" id i))
              | Some (_, group) as cached ->
                  let slice = Bigarray.Array1.sub buf done_ take in
                  let* served = Cc.read_into ~group ~index:i slice ~chunk_off in
                  let got = served.Cc.bytes in
                  (* The group's size, not the slice's: what came down the wire
                     is the whole group, however little of it this read wanted. *)
                  if served.Cc.from_backend then
                    credit_pull id ~size:(Int64.to_int size)
                      (Chunk_group.bytes group);
                  if got <= 0 then Lwt.return done_
                  else go (pos + got) (done_ + got) cached))
      in
      let* got = go start 0 None in
      let last = min (n - 1) ((start + max 0 (got - 1)) / cs) in
      if Hashtbl.find_opt last_read_end id = Some start then
        read_ahead ~id ~size:(Int64.to_int size) ~table ~per ~chunk_size:cs
          ~last;
      Hashtbl.replace last_read_end id (start + got);
      Lwt.return got)

  let rec pread_staged ~id ~(staged : Manifest.staged) ~base buf ~offset =
    match staged.Manifest.s_whole with
      | Some uuid ->
          let want = Bigarray.Array1.dim buf in
          let avail = Int64.to_int (Int64.sub staged.Manifest.s_size offset) in
          let total = min want (max 0 avail) in
          if total <= 0 then Lwt.return 0
          else
            Cc.whole_read_into ~uuid (Bigarray.Array1.sub buf 0 total) ~offset
      | None -> pread_chunked ~id ~staged ~base buf ~offset

  and pread_chunked ~id ~(staged : Manifest.staged) ~base buf ~offset =
    let cs = staged.Manifest.s_chunk_size in
    let want = Bigarray.Array1.dim buf in
    let start = Int64.to_int offset in
    let avail = Int64.to_int (Int64.sub staged.Manifest.s_size offset) in
    let total = min want (max 0 avail) in
    if total <= 0 || cs <= 0 then Lwt.return 0
    else (
      let slots = staged.Manifest.s_slots in
      let n = Array.length slots in

      let rec go pos done_ =
        if done_ >= total then Lwt.return done_
        else (
          let i = pos / cs in
          if i >= n then Lwt.return done_
          else (
            let chunk_off = pos mod cs in
            let take = min (cs - chunk_off) (total - done_) in
            let slice = Bigarray.Array1.sub buf done_ take in
            let* got =
              match slots.(i) with
                | Manifest.Staged { uuid; offset = body_off } ->
                    let* got =
                      Cc.stage_read_into ~uuid slice
                        ~offset:(body_off + chunk_off)
                    in
                    (* A staged body is only as long as the writes that reached
                       it: past its end is a hole, reading as zeros. *)
                    if got < take then (
                      Bigarray.Array1.fill
                        (Bigarray.Array1.sub slice got (take - got))
                        '\000';
                      Lwt.return take)
                    else Lwt.return got
                | Manifest.Zero ->
                    Bigarray.Array1.fill slice '\000';
                    Lwt.return take
                | Manifest.Inherit -> (
                    match Mf.group_at_opt base i with
                      | Some group ->
                          let+ served =
                            Cc.read_into ~group ~index:i slice ~chunk_off
                          in
                          if served.Cc.from_backend then
                            credit_pull id
                              ~size:(Int64.to_int staged.Manifest.s_size)
                              (Chunk_group.bytes group);
                          served.Cc.bytes
                      | None ->
                          Lwt.fail
                            (Backend.Backend_error
                               (Printf.sprintf
                                  "staged %s: chunk %d inherits nothing" id i)))
            in
            if got <= 0 then Lwt.return done_ else go (pos + got) (done_ + got)))
      in
      go start 0)

  (* ponytail: one GET per uncached file; add a metadata cache if a cold
     full-directory enumeration gets slow. *)
  let resolved_manifest key =
    let* m = Mf.read key in
    match m with Some _ -> Lwt.return m | None -> R.fetch_manifest ~key ()

  (* A promotion can retire the staged bodies between resolving the key and
     reading them, so a miss is resolved again and read once more. The retry
     finds the published manifest because {!promote} puts it in place before any
     body goes, the same shape as {!Chunk_cache.read_into} against the cap. *)
  let pread_key key buf ~offset =
    let attempt () =
      let* resolved = Mf.resolve key in
      match resolved with
        | Some (`Staged (staged, base)) ->
            pread_staged ~id:key ~staged ~base buf ~offset
        | Some (`Published m) -> pread ~id:key ~manifest:m buf ~offset
        | None -> (
            let* state = R.fetch_manifest ~key () in
            match state with
              | Some m -> pread ~id:key ~manifest:m buf ~offset
              | None -> Lwt.return 0)
    in
    Lwt.catch attempt (function
      | Unix.Unix_error (Unix.ENOENT, _, _) -> attempt ()
      | exn -> Lwt.fail exn)

  (* One mutation of a key at a time. Promotion hands a staged body to the chunk
     store under its content name, so a write arriving partway through would
     change bytes the upload has already hashed and published.

     Reads stay outside it: verifying a large file holds the key for as long as
     the read takes, which is exactly the caller a promotion must not wait for. *)
  let key_locks : (string, Lwt_mutex.t * int ref) Hashtbl.t = Hashtbl.create 16

  let with_key key f =
    let entry =
      match Hashtbl.find_opt key_locks key with
        | Some entry -> entry
        | None ->
            let entry = (Lwt_mutex.create (), ref 0) in
            Hashtbl.replace key_locks key entry;
            entry
    in
    let mutex, holders = entry in
    incr holders;
    Lwt.finalize
      (fun () -> Lwt_mutex.with_lock mutex f)
      (fun () ->
        decr holders;
        if !holders = 0 then Hashtbl.remove key_locks key;
        Lwt.return_unit)

  (* Where each member of a group sits in the body that holds it: the running
     sum of the lengths before it, which is what {!Chunk_group.offset} computes
     for the published group these bytes become. *)
  let group_layout ~(st : Manifest.staged) ~first ~last =
    let len j =
      Manifest.chunk_len ~size:st.Manifest.s_size
        ~chunk_size:st.Manifest.s_chunk_size j
    in
    let rec go j offset acc =
      if j > last then (List.rev acc, offset)
      else go (j + 1) (offset + len j) ((j, offset, len j) :: acc)
    in
    go first 0 []

  (* A whole body is split into chunks first: only chunks can be addressed by a
     partial write. *)
  let rec staged_for key =
    let* st = Mf.read_staged key in
    match st with
      | Some ({ Manifest.s_whole = Some uuid; _ } as st) ->
          let* () = split_whole key st uuid in
          staged_for key
      | Some st -> Lwt.return st
      | None -> (
          let* chunk_size = R.chunk_size () in
          let+ published = Mf.read key in
          let name = Key.leaf ~domain_prefix:C.domain_prefix key in
          match published with
            | Some m ->
                {
                  (* The key names this file; the published body names whatever
                     it was filed as. *)
                  Manifest.s_name = name;
                  s_size = m.Manifest.size;
                  s_mtime = Unix.gettimeofday ();
                  s_chunk_size = m.Manifest.chunk_size;
                  s_slots =
                    Array.make
                      (Manifest.num_chunks_for m.Manifest.size
                         m.Manifest.chunk_size)
                      Manifest.Inherit;
                  s_whole = None;
                  s_published = None;
                }
            | None ->
                {
                  Manifest.s_name = name;
                  s_size = 0L;
                  s_mtime = Unix.gettimeofday ();
                  s_chunk_size = chunk_size;
                  s_slots = [||];
                  s_whole = None;
                  s_published = None;
                })

  and split_whole key (st : Manifest.staged) uuid =
    let* cs = R.chunk_size () in
    let n = Manifest.num_chunks_for st.Manifest.s_size cs in
    let slots = Array.make n Manifest.Zero in
    let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout cs in
    let per = Chunk_group.per_group ~chunk_size:cs ~cache_chunk_size in
    let st_for_layout = { st with Manifest.s_chunk_size = cs } in
    let rec chunk i body offset =
      if i >= n then Lwt.return_unit
      else
        let* body, offset =
          if Chunk_group.index_of ~per i * per = i then (
            let body = Manifest.new_uuid () in
            let last = min (n - 1) (i + per - 1) in
            let _, body_len = group_layout ~st:st_for_layout ~first:i ~last in
            let+ () = Cc.stage_ensure ~uuid:body ~len:body_len in
            (body, 0))
          else Lwt.return (body, offset)
        in
        let len =
          Manifest.chunk_len ~size:st.Manifest.s_size ~chunk_size:cs i
        in
        let slice = Bigarray.Array1.sub buf 0 len in
        let* (_ : int) =
          Cc.whole_read_into ~uuid slice ~offset:(Int64.of_int (i * cs))
        in
        let* (_ : int) = Cc.stage_write ~uuid:body slice ~offset in
        slots.(i) <- Manifest.Staged { uuid = body; offset };
        chunk (i + 1) body (offset + len)
    in
    let* () = chunk 0 "" 0 in
    let st =
      {
        st with
        Manifest.s_slots = slots;
        s_chunk_size = cs;
        s_whole = None;
        s_published = None;
      }
    in
    let* () = Mf.write_staged key st in
    Cc.whole_forget ~uuid

  (* [s_published] is the manifest an upload published for the bytes it hashed,
     so changing those bytes retires it: leaving it set promotes a description of
     what the file used to hold. *)
  let mutated (st : Manifest.staged) =
    { st with Manifest.s_mtime = Unix.gettimeofday (); s_published = None }

  let grow_slots slots n =
    let old = Array.length slots in
    if n <= old then slots
    else (
      let a = Array.make n Manifest.Zero in
      Array.blit slots 0 a 0 old;
      a)

  (* The body a group's staged members share, when they share one: the same
     uuid, each at the offset [members] says it belongs at. [Zero] members are
     skipped, since a hole is whatever the body already holds there. *)
  let shared_body ~slot_at members =
    List.fold_left
      (fun acc (j, offset) ->
        match (acc, slot_at j) with
          | `No, _ -> `No
          | acc, Manifest.Zero -> acc
          | `Unset, Manifest.Staged b when b.Manifest.offset = offset ->
              `Body b.Manifest.uuid
          | `Body u, Manifest.Staged b
            when b.Manifest.uuid = u && b.Manifest.offset = offset ->
              `Body u
          | _ -> `No)
      `Unset members
    |> function
    | `Body uuid -> Some uuid
    | `Unset | `No -> None

  (* Establishes that every staged member of the group [i] falls in shares one
     body and sits at its layout offset, so the body is the group's bytes
     already assembled and publishing it is a link rather than a copy.

     The whole group is staged, never part of it: the group's key covers all its
     members, so a body holding only some of them could not be published under
     the key the others still name. *)
  let ensure_group_body ~base ~(st : Manifest.staged) ~covers i =
    let slots = st.Manifest.s_slots in
    let per =
      Chunk_group.per_group ~chunk_size:st.Manifest.s_chunk_size
        ~cache_chunk_size
    in
    let n = Array.length slots in
    let first = Chunk_group.index_of ~per i * per in
    let last = min (n - 1) (first + per - 1) in
    let members, body_len = group_layout ~st ~first ~last in

    (* Already one body at the right offsets, which is a second write to a group
       it has staged before: no copy. *)
    let shared =
      shared_body
        ~slot_at:(fun j -> slots.(j))
        (List.map (fun (j, offset, _) -> (j, offset)) members)
    in
    match shared with
      | Some uuid ->
          let+ () = Cc.stage_ensure ~uuid ~len:body_len in
          (* Every hole in the group becomes part of the body, covered by this
             write or not: the body is sparse there, which is the same bytes a
             hole reads as, and a member left behind is one the write is about
             to be told it cannot address. *)
          List.iter
            (fun (j, offset, _) ->
              match slots.(j) with
                | Manifest.Zero -> slots.(j) <- Manifest.Staged { uuid; offset }
                | Manifest.Staged _ | Manifest.Inherit -> ())
            members
      | None ->
          let uuid = Manifest.new_uuid () in
          let stale = Manifest.body_uuids slots in
          let* () = Cc.stage_ensure ~uuid ~len:body_len in
          let* () =
            Lwt_list.iter_s
              (fun (j, offset, len) ->
                (* A member the write is about to replace whole needs nothing
                   read in. *)
                if covers j then Lwt.return_unit
                else (
                  match slots.(j) with
                    | Manifest.Staged b ->
                        Cc.stage_copy ~src:b.Manifest.uuid
                          ~src_off:b.Manifest.offset ~dst:uuid ~dst_off:offset
                          ~len
                    | Manifest.Inherit -> (
                        match Mf.group_at_opt base j with
                          | Some group ->
                              Cc.stage_copy_chunk ~group ~index:j ~uuid ~offset
                          (* Nothing published to inherit: a hole, and the body
                             is already sparse there. *)
                          | None -> Lwt.return_unit)
                    | Manifest.Zero -> Lwt.return_unit))
              members
          in
          List.iter
            (fun (j, offset, _) ->
              slots.(j) <- Manifest.Staged { uuid; offset })
            members;
          let live = Manifest.body_uuids slots in
          Lwt_list.iter_s
            (fun old ->
              if List.mem old live then Lwt.return_unit
              else Cc.stage_forget ~uuid:old)
            stale

  (* Bytes land before the staged manifest: a crash in between leaves an
     unreferenced body rather than a manifest pointing at unwritten bytes. *)
  let write_locked key buf ~offset =
    let len = Bigarray.Array1.dim buf in
    let* st = staged_for key in
    let* base = Mf.read key in
    let cs = st.Manifest.s_chunk_size in
    let start = Int64.to_int offset in
    let new_size =
      Int64.of_int (max (Int64.to_int st.Manifest.s_size) (start + len))
    in
    let slots =
      grow_slots st.Manifest.s_slots (Manifest.num_chunks_for new_size cs)
    in
    let st = { st with Manifest.s_slots = slots; s_size = new_size } in
    let first = start / cs in
    let last = if len = 0 then first else (start + len - 1) / cs in
    (* Asked of every member of a group, not just the chunk being written, so
       overwriting a whole file costs no reads. *)
    let covers j =
      let chunk_start = j * cs in
      start <= chunk_start
      && start + len
         >= chunk_start + Manifest.chunk_len ~size:new_size ~chunk_size:cs j
    in
    let rec go i =
      if i > last then Lwt.return_unit
      else (
        let chunk_off = if i = first then start mod cs else 0 in
        let take =
          min (cs - chunk_off) (len - ((i * cs) + chunk_off - start))
        in
        let* () = ensure_group_body ~base ~st ~covers i in
        let* () =
          match st.Manifest.s_slots.(i) with
            | Manifest.Staged { uuid; offset = body_off } ->
                let src_off = (i * cs) + chunk_off - start in
                let slice = Bigarray.Array1.sub buf src_off take in
                let+ (_ : int) =
                  Cc.stage_write ~uuid slice ~offset:(body_off + chunk_off)
                in
                ()
            | Manifest.Inherit | Manifest.Zero ->
                (* [ensure_group_body] just made this a staged body. *)
                Lwt.fail_with "data: slot not staged"
        in
        go (i + 1))
    in
    let* () = go first in
    let+ () = Mf.write_staged key (mutated st) in
    len

  (* A grow is pure metadata: new chunks are holes until written. *)
  let write key buf ~offset =
    with_key key (fun () -> write_locked key buf ~offset)

  let truncate_locked key size =
    let* st = staged_for key in
    let* base = Mf.read key in
    let cs = st.Manifest.s_chunk_size in
    let n = Manifest.num_chunks_for size cs in
    let old = st.Manifest.s_slots in
    let slots = grow_slots (Array.sub old 0 (min n (Array.length old))) n in
    (* By difference, not per dropped slot: the members of a group share one
       body, and one of them surviving keeps it. *)
    let* () =
      let kept = Manifest.body_uuids slots in
      Lwt_list.iter_s
        (fun uuid ->
          if List.mem uuid kept then Lwt.return_unit else Cc.stage_forget ~uuid)
        (Manifest.body_uuids old)
    in
    let st = { st with Manifest.s_slots = slots; s_size = size } in
    let* () =
      let i = n - 1 in
      if i < 0 then Lwt.return_unit
      else (
        let len = Manifest.chunk_len ~size ~chunk_size:cs i in
        match slots.(i) with
          | Manifest.Staged { uuid; offset } ->
              Cc.stage_resize ~uuid ~len:(offset + len)
          | Manifest.Zero -> Lwt.return_unit
          | Manifest.Inherit -> (
              let inherited_len =
                match base with
                  | Some m ->
                      Manifest.chunk_len ~size:m.Manifest.size
                        ~chunk_size:m.Manifest.chunk_size i
                  | None -> 0
              in
              if inherited_len = len then Lwt.return_unit
              else
                let* () =
                  ensure_group_body ~base ~st ~covers:(fun _ -> false) i
                in
                match slots.(i) with
                  | Manifest.Staged { uuid; offset } ->
                      Cc.stage_resize ~uuid ~len:(offset + len)
                  | Manifest.Inherit | Manifest.Zero -> Lwt.return_unit))
    in
    Mf.write_staged key (mutated st)

  let discard_bodies (st : Manifest.staged) =
    let* () =
      Lwt_list.iter_s
        (fun uuid -> Cc.stage_forget ~uuid)
        (Manifest.body_uuids st.Manifest.s_slots)
    in
    match st.Manifest.s_whole with
      | Some uuid -> Cc.whole_forget ~uuid
      | None -> Lwt.return_unit

  let truncate key size = with_key key (fun () -> truncate_locked key size)

  let discard_staged_locked key =
    let* st = Mf.read_staged key in
    let* () =
      match st with Some st -> discard_bodies st | None -> Lwt.return_unit
    in
    Mf.delete_staged key

  (* Staged bodies are named by uuid and referenced only from staged manifests,
     so a body no manifest names is unreachable by construction.

     Startup only: {!stage_slot} creates a body before the manifest records it,
     so mid-session an unreferenced body can be one a write is about to use. *)
  let reclaim_staged_orphans () =
    let* uuids = Mf.staged_uuids () in
    let live = Hashtbl.create (List.length uuids) in
    List.iter (fun uuid -> Hashtbl.replace live uuid ()) uuids;
    let sweep dir =
      let* exists = Fs_util.is_directory dir in
      if not exists then Lwt.return_unit
      else
        let* names = Fs_util.readdir_list dir in
        Lwt_list.iter_s
          (fun name ->
            if Hashtbl.mem live name then Lwt.return_unit
            else (
              Log.info "reclaiming orphaned staged body %s" name;
              Fs_util.unlink_quiet (Filename.concat dir name)))
          names
    in
    let* () =
      sweep
        (Cache_layout.staged_chunks_dir ~cache_root:C.cache_root C.domain_name)
    in
    let* () =
      sweep
        (Cache_layout.staged_whole_dir ~cache_root:C.cache_root C.domain_name)
    in
    Mf.prune_staged_dirs ()

  let discard_staged key = with_key key (fun () -> discard_staged_locked key)

  let create_locked key =
    let* st = Mf.read_staged key in
    let* () =
      match st with Some st -> discard_bodies st | None -> Lwt.return_unit
    in
    let name = Key.leaf ~domain_prefix:C.domain_prefix key in
    let* chunk_size = R.chunk_size () in
    Mf.write_staged key
      {
        Manifest.s_name = name;
        s_size = 0L;
        s_mtime = Unix.gettimeofday ();
        s_chunk_size = chunk_size;
        s_slots = [||];
        s_whole = None;
        s_published = None;
      }

  let create key = with_key key (fun () -> create_locked key)

  (* A staged body is whatever the writer left on disk and may fall short of its
     chunk length, grown by a truncate that never wrote or lost entirely.

     The manifest's length wins either way, so a short or missing body zeroes the
     tail rather than shrinking the chunk. *)
  let fill_from_staged ~uuid ~offset ~len buf =
    let* fd =
      Lwt.catch
        (fun () ->
          let+ fd =
            Lwt_unix_retry.openfile (Cc.staged_path uuid) [Unix.O_RDONLY] 0
          in
          Some fd)
        (fun _ -> Lwt.return_none)
    in
    match fd with
      | None ->
          Local_io.zero buf ~pos:0 ~len;
          Lwt.return_unit
      | Some fd ->
          Lwt.finalize
            (fun () ->
              let rec loop pos =
                if pos >= len then Lwt.return_unit
                else
                  let* n =
                    Local_io.pread fd buf ~file_offset:(offset + pos) pos
                      (len - pos)
                  in
                  (* Short of [len]: the rest of the chunk is a hole. *)
                  if n = 0 then (
                    Local_io.zero buf ~pos ~len:(len - pos);
                    Lwt.return_unit)
                  else loop (pos + n)
              in
              loop 0)
            (fun () -> Lwt_unix_retry.close fd)

  (* Deciding which source a chunk has must stay I/O-free: the reads happen
     inside the fillers, once {!Remote.upload_chunks} has a buffer to hand
     them. *)
  let staged_source ~(staged : Manifest.staged) ~base i =
    let cs = staged.Manifest.s_chunk_size in
    let len =
      Manifest.chunk_len ~size:staged.Manifest.s_size ~chunk_size:cs i
    in
    let zeroes =
      `Fill
        (fun buf ->
          Local_io.zero buf ~pos:0 ~len;
          Lwt.return_unit)
    in
    let slots = staged.Manifest.s_slots in
    if i >= Array.length slots then Lwt.return zeroes
    else (
      match slots.(i) with
        | Manifest.Zero -> Lwt.return zeroes
        | Manifest.Inherit -> (
            match base with
              | Some m when i < Chunk_table.count m.Manifest.chunks ->
                  Lwt.return (`Reuse (Chunk_table.key m.Manifest.chunks i))
              | Some _ | None ->
                  Lwt.fail
                    (Backend.Backend_error
                       (Printf.sprintf "staged chunk %d inherits nothing" i)))
        | Manifest.Staged { uuid; offset } ->
            Lwt.return
              (`Fill (fun buf -> fill_from_staged ~uuid ~offset ~len buf)))

  let rec upload_staged ~key ~(staged : Manifest.staged) ?cancel () =
    match staged.Manifest.s_whole with
      | Some uuid ->
          let* chunk_size = R.chunk_size () in
          let* state =
            R.upload ~key ~src_path:(Cc.whole_path uuid)
              ~mtime:staged.Manifest.s_mtime ~chunk_size ?cancel ()
          in
          commit key staged state
      | None -> upload_chunked ~key ~staged ?cancel ()

  and upload_chunked ~key ~(staged : Manifest.staged) ?cancel () =
    let* base = Mf.read key in
    let* state =
      R.upload_chunks ~key ~size:staged.Manifest.s_size
        ~chunk_size:staged.Manifest.s_chunk_size ~mtime:staged.Manifest.s_mtime
        ~source:(staged_source ~staged ~base)
        ?cancel ()
    in
    commit key staged state

  (* Written before anything local moves: a crash before this re-uploads
     identical bytes, after it only local moves are left to replay. *)
  and commit key (staged : Manifest.staged) published =
    let+ () =
      Mf.write_staged key { staged with Manifest.s_published = Some published }
    in
    published

  (* Every step is idempotent, so a crash anywhere replays.

     Bodies go last, after the published manifest and after the marker that
     chooses between the two: a reader resolving the key partway through has to
     find whichever representation it lands on still on disk. *)
  let rec promote key (staged : Manifest.staged) (published : Manifest.t) =
    match staged.Manifest.s_whole with
      | Some uuid ->
          (* The chunk store deliberately ends up with none of this file's
             chunks: the only caller handing over whole files is the FileProvider
             extension, which already keeps its own copy, and caching the bytes
             again would double the disk cost of every edit. *)
          let* () = Mf.write key published in
          let* () = Mf.delete_staged key in
          Cc.whole_forget ~uuid
      | None -> promote_chunked key staged published

  and promote_chunked key (staged : Manifest.staged) (published : Manifest.t) =
    let slots = staged.Manifest.s_slots in
    let slot_at i =
      if i < Array.length slots then slots.(i) else Manifest.Zero
    in
    let touched group =
      List.exists
        (fun i -> match slot_at i with Manifest.Staged _ -> true | _ -> false)
        (Chunk_group.indices group)
    in
    (* [stage_group] stages a group whole, so a touched group has every member
       on disk; anything else would come from the old, invalidated group key. *)
    let local group =
      List.for_all
        (fun i ->
          match slot_at i with
            | Manifest.Staged _ | Manifest.Zero -> true
            | Manifest.Inherit -> false)
        (Chunk_group.indices group)
    in
    (* Anything else -- a body per chunk from an older sidecar, or a group the
       cache size no longer matches -- has to be written out. *)
    (* The staged record's own account of the group's length, which the link
       refuses unless it matches the published group's. *)
    let staged_len group =
      let indices = Chunk_group.indices group in
      match indices with
        | [] -> 0
        | first :: _ ->
            let last = List.nth indices (List.length indices - 1) in
            snd (group_layout ~st:staged ~first ~last)
    in
    let single_body group =
      shared_body ~slot_at
        (List.map
           (fun i -> (i, Chunk_group.offset group i))
           (Chunk_group.indices group))
    in
    let write_group group =
      Cc.put_group ~group ~member:(fun i ->
          let* source = staged_source ~staged ~base:None i in
          match source with
            | `Reuse _ -> assert false (* [local] ruled this out *)
            | `Fill fill ->
                (* Its own buffer rather than one of the upload path's slots:
                   this runs over a group's members, two at the defaults. *)
                let len =
                  Manifest.chunk_len ~size:staged.Manifest.s_size
                    ~chunk_size:staged.Manifest.s_chunk_size i
                in
                let buf = Chunk.create len in
                let+ () = fill buf in
                Chunk.of_buffer buf)
    in
    (* An untouched group keeps its key, so whatever body we hold for it is
       still right. *)
    let* () =
      Lwt_list.iter_s
        (fun group ->
          if not (touched group && local group) then Lwt.return_unit
          else (
            match single_body group with
              | Some uuid ->
                  let* linked =
                    Cc.stage_link_group ~uuid ~len:(staged_len group) ~group
                  in
                  if linked then Lwt.return_unit else write_group group
              | None -> write_group group))
        (Mf.groups published)
    in
    let* () = Mf.write key published in
    let* () = Mf.delete_staged key in
    discard_bodies staged

  (* Read again under the lock rather than promoting the record the upload
     started from: a write since then has retired it, and what it describes is
     no longer what the file holds. The next close or the next start queues the
     upload that owes. *)
  let promote_pending key =
    with_key key (fun () ->
        let* staged = Mf.read_staged key in
        match staged with
          | Some ({ Manifest.s_published = Some published; _ } as staged) ->
              promote key staged published
          | _ ->
              Log.debug "sync %s: superseded before promotion" key;
              Lwt.return_unit)

  (* A staged manifest already carrying a published one was interrupted
     mid-promotion: finish it without re-uploading. *)
  let sync key ?cancel () =
    let* staged = Mf.read_staged key in
    match staged with
      | None -> Lwt.return_unit
      | Some { Manifest.s_published = Some _; _ } -> promote_pending key
      | Some staged ->
          let* (_ : Manifest.t) = upload_staged ~key ~staged ?cancel () in
          promote_pending key

  (* Re-exported so a domain has exactly one {!Chunk_cache} instance: two would
     each keep their own in-flight table and stop deduplicating downloads. *)

  let enforce_chunk_cap = Cc.enforce_cap
  let chunk_stats = Cc.stats
  let downloads_in_flight = Cc.in_flight

  (* Adopts [src_path] by rename: no copy, no chunking pass; the upload reads it
     directly. *)
  let stage_whole_locked key ~src_path =
    let* st = Mf.read_staged key in
    let* () =
      match st with Some st -> discard_bodies st | None -> Lwt.return_unit
    in
    let* stat = Lwt_unix_retry.LargeFile.stat src_path in
    let* chunk_size = R.chunk_size () in
    let uuid = Manifest.new_uuid () in
    let* () = Cc.adopt_whole ~src:src_path ~uuid in
    Mf.write_staged key
      {
        Manifest.s_name = Key.leaf ~domain_prefix:C.domain_prefix key;
        s_size = stat.Unix.LargeFile.st_size;
        s_mtime = stat.Unix.LargeFile.st_mtime;
        s_chunk_size = chunk_size;
        s_slots = [||];
        s_whole = Some uuid;
        s_published = None;
      }

  let stage_whole key ~src_path =
    with_key key (fun () -> stage_whole_locked key ~src_path)

  let staged_body_path key =
    let+ st = Mf.read_staged key in
    match st with
      | Some { Manifest.s_whole = Some uuid; _ } -> Some (Cc.whole_path uuid)
      | _ -> None

  (* Staged bodies count as present: they are the newest bytes there are. *)
  let chunk_residency key =
    let* resolved = Mf.resolve key in
    match resolved with
      | None -> Lwt.return (0, 0)
      | Some (`Published m) ->
          let total = Chunk_table.count m.Manifest.chunks in
          let+ present =
            Lwt_list.fold_left_s
              (fun acc group ->
                let+ here = Cc.exists group in
                if here then acc + Chunk_group.member_count group else acc)
              0 (Mf.groups m)
          in
          (present, total)
      | Some (`Staged (({ Manifest.s_whole = Some _; _ } as st), _)) ->
          let n =
            Manifest.num_chunks_for st.Manifest.s_size st.Manifest.s_chunk_size
          in
          Lwt.return (n, n)
      | Some (`Staged (st, base)) ->
          let slots = st.Manifest.s_slots in
          let total = Array.length slots in
          let+ present =
            Lwt_list.fold_left_s
              (fun acc i ->
                match slots.(i) with
                  | Manifest.Staged _ | Manifest.Zero -> Lwt.return (acc + 1)
                  | Manifest.Inherit -> (
                      match Mf.group_at_opt base i with
                        | Some group ->
                            let+ here = Cc.exists group in
                            if here then acc + 1 else acc
                        | None -> Lwt.return acc))
              0 (List.init total Fun.id)
          in
          (present, total)

  (* [total] counts fetch *and* reassembly bytes: a bar that stops at the end of
     the fetch cannot be told from a hang.

     [holders] lets two materializations of one key share a row instead of the
     first to finish taking it away from the other. *)
  type span = { mutable fetched : int; total : int; mutable holders : int }

  let active : (string, span) Hashtbl.t = Hashtbl.create 8

  let download_progress key =
    Option.map (fun s -> (s.fetched, s.total)) (Hashtbl.find_opt active key)

  (* Clamped: a group already on disk is credited in full, so a re-fetch would
     otherwise push the bar past its end. *)
  let credit key n =
    match Hashtbl.find_opt active key with
      | Some s -> s.fetched <- min s.total (s.fetched + n)
      | None -> ()

  let with_span key ~total f =
    (match Hashtbl.find_opt active key with
      | Some s -> s.holders <- s.holders + 1
      | None -> Hashtbl.replace active key { fetched = 0; total; holders = 1 });
    Lwt.finalize f (fun () ->
        (match Hashtbl.find_opt active key with
          | Some s when s.holders <= 1 -> Hashtbl.remove active key
          | Some s -> s.holders <- s.holders - 1
          | None -> ());
        Lwt.return_unit)

  let groups_bytes groups =
    List.fold_left (fun acc g -> acc + Chunk_group.bytes g) 0 groups

  (* Every group is asked for at once; the bound lives in
     {!Chunk_cache.ensure}, which limits what a request goes on to do.

     ponytail: credit is per group — 16 MB at the defaults, so a file smaller
     than one group only moves when it finishes; doing it per stored chunk needs
     a listener registry, since {!Chunk_cache.ensure} hands a second caller the
     in-flight promise without its callback. *)
  let fetch_groups key groups =
    (* What is owed the network, not the size of the file: a partly cached file
       finishes sooner, and an ETA is against what is left to come down. *)
    let owed = groups_bytes groups in
    Lwt_list.iter_p
      (fun group ->
        let+ fetched = Cc.ensure_fetched ~group () in
        let bytes = Chunk_group.bytes group in
        (* The bar counts every group: one already on disk is progress toward a
           materialized file. The tray row counts only what crossed the wire, or
           a part-cached file credits its local groups at once and reads as a
           rate in the gigabytes. *)
        credit key bytes;
        if fetched then credit_pull key ~size:owed bytes)
      groups

  (* Counted here, not at the callers, so every route to a materialized file is
     included. *)
  let downloads_completed = ref 0
  let downloads_completed_count () = !downloads_completed

  (* Which groups [key] still owes the network, resolved up front so a caller
     can size a progress bar; [None] is "nothing to materialize", distinct from
     the empty list a chunkless file gives. *)
  let fetch_plan key =
    let* resolved = Mf.resolve key in
    match resolved with
      | Some (`Published m) -> Lwt.return_some (Mf.groups m)
      | Some (`Staged (st, base)) -> (
          match base with
            | None -> Lwt.return_none
            | Some m ->
                let slots = st.Manifest.s_slots in
                let still_inherited i =
                  i < Array.length slots && slots.(i) = Manifest.Inherit
                in
                Lwt.return_some
                  (List.filter
                     (fun g ->
                       List.exists still_inherited (Chunk_group.indices g))
                     (Mf.groups m)))
      | None -> (
          let* state = R.fetch_manifest ~key () in
          match state with
            | Some m ->
                let* () = Mf.write key m in
                Lwt.return_some (Mf.groups m)
            | None -> Lwt.return_none)

  let content_size key =
    let+ resolved = Mf.resolve key in
    match resolved with
      | Some (`Published m) -> Int64.to_int m.Manifest.size
      | Some (`Staged (st, _)) -> Int64.to_int st.Manifest.s_size
      | None -> 0

  let ensure_local key =
    let* plan = fetch_plan key in
    match plan with
      | None -> Lwt.return_unit
      | Some groups ->
          with_span key ~total:(groups_bytes groups) (fun () ->
              let+ () = fetch_groups key groups in
              incr downloads_completed)

  (* Goes through the ordinary read path, so staged edits, inherited chunks and
     holes all come out right and the chunk store is populated on the way. *)
  let assemble_to key ~dst_path =
    let* () = Fs_util.ensure_parent dst_path in
    let* plan = fetch_plan key in
    let* size = content_size key in
    let to_fetch = match plan with None -> 0 | Some gs -> groups_bytes gs in
    with_span key ~total:(to_fetch + size) @@ fun () ->
    let* () =
      match plan with
        | None -> Lwt.return_unit
        | Some groups ->
            let+ () = fetch_groups key groups in
            incr downloads_completed
    in
    let buf =
      Bigarray.Array1.create Bigarray.char Bigarray.c_layout cache_chunk_size
    in
    let* fd =
      Lwt_unix_retry.openfile dst_path
        [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
        0o644
    in
    let* () = Lwt_unix_retry.close fd in
    let rec go offset =
      let* n = pread_key key buf ~offset in
      if n <= 0 then Lwt.return_unit
      else
        let* (_ : int) =
          Local_io.write dst_path (Bigarray.Array1.sub buf 0 n) ~offset
        in
        credit key n;
        go (Int64.add offset (Int64.of_int n))
    in
    let* () = go 0L in
    (* An export or handoff copy should carry the source file's mtime. *)
    let* resolved = Mf.resolve key in
    match resolved with
      | Some (`Staged (st, _)) ->
          Lwt_unix_retry.utimes dst_path st.Manifest.s_mtime st.Manifest.s_mtime
      | Some (`Published m) ->
          Lwt_unix_retry.utimes dst_path m.Manifest.mtime m.Manifest.mtime
      | None -> Lwt.return_unit

  (* ponytail: no progress span — a range is bounded by construction and its
     caller knows how many bytes it asked for. *)
  let fetch_range key ~dst_path ~offset ~length =
    let* () = Fs_util.ensure_parent dst_path in
    let* fd =
      Lwt_unix_retry.openfile dst_path [Unix.O_WRONLY; Unix.O_CREAT] 0o644
    in
    let* () = Lwt_unix_retry.close fd in
    let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout length in
    let offset = Int64.of_int offset in
    let* n = pread_key key buf ~offset in
    let+ (_ : int) =
      Local_io.write dst_path (Bigarray.Array1.sub buf 0 n) ~offset
    in
    n

  (* Unreference-blind: a chunk shared with another file goes too and is
     re-fetched on demand, which is what avoids refcounting. *)
  let forget_chunks key =
    let* published = Mf.read key in
    match published with
      | Some m -> Lwt_list.iter_s (fun group -> Cc.forget ~group) (Mf.groups m)
      | None -> Lwt.return_unit
end
