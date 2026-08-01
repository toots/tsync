(* File content as bytes, served per cache chunk out of {!Chunk_cache}.

   A file is never assembled: a read maps its byte range onto the stored chunks
   backing it and copies out of the cache chunks those group into, fetching what
   is absent. Nothing records which chunks are local — the store answers that by
   existing — so there is no per-file state beyond a read-ahead hint.
   {!Chunk_group} is the only thing between the two granularities; above it,
   everything counts in stored chunks. *)

open Lwt.Syntax

(* Read-ahead applies to sequential reads only. *)
let readahead_bytes = 4 * 1024 * 1024
let max_readahead_groups = 8

module Make (C : Conf.S) (R : Remote.S) = struct
  module Cc = Chunk_cache.Make (C) (R)
  module Mf = Manifest.Make (C)

  (* Advisory: a lost or stale entry costs at most one un-prefetched read. *)
  let last_read_end : (string, int) Hashtbl.t = Hashtbl.create 64
  let cache_chunk_size = Conf.cache_chunk_size (module C)

  (* Reuses [cached] while [i] stays in the same group, so a sequential read
     rebuilds one group per boundary crossing rather than one per chunk. *)
  let group_at ~table ~per ~cached i =
    let gi = Chunk_group.index_of ~per i in
    match cached with
      | Some (j, g) when j = gi -> Some (gi, g)
      | _ -> Option.map (fun g -> (gi, g)) (Chunk_group.of_table ~table ~per i)

  let read_ahead ~table ~per ~chunk_size ~last =
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
                      | Some group -> Cc.ensure ~group ()
                      | None -> Lwt.return_unit
                  in
                  go (i + per)
              in
              go first)
            (fun _ -> Lwt.return_unit))

  (* [id] is used for the read-ahead heuristic only. Returns bytes read, short
     only at end of file. *)
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
                  let* got = Cc.read_into ~group ~index:i slice ~chunk_off in
                  if got <= 0 then Lwt.return done_
                  else go (pos + got) (done_ + got) cached))
      in
      let* got = go start 0 None in
      let last = min (n - 1) ((start + max 0 (got - 1)) / cs) in
      if Hashtbl.find_opt last_read_end id = Some start then
        read_ahead ~table ~per ~chunk_size:cs ~last;
      Hashtbl.replace last_read_end id (start + got);
      Lwt.return got)

  (* Sources, in order: the whole body a frontend handed over, else per chunk
     from its staged body, the published chunk it inherits, or a hole left by a
     grow (reads as zeros). *)
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
                | Manifest.Staged uuid ->
                    let* got = Cc.stage_read_into ~uuid slice ~chunk_off in
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
                          Cc.read_into ~group ~index:i slice ~chunk_off
                      | None ->
                          Lwt.fail
                            (Backend.Backend_error
                               (Printf.sprintf
                                  "staged %s: chunk %d inherits nothing" id i)))
            in
            if got <= 0 then Lwt.return done_ else go (pos + got) (done_ + got)))
      in
      go start 0)

  (* Sidecar first, else the backend, so a file that was never cached still
     reports its logical size and mtime rather than the manifest object's own
     byte size.
     ponytail: one GET per uncached file; add a metadata cache if a cold
     full-directory enumeration gets slow. *)
  let resolved_manifest key =
    let* m = Mf.read key in
    match m with Some _ -> Lwt.return m | None -> R.fetch_manifest ~key ()

  let pread_key key buf ~offset =
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

  (* The staged manifest a write starts from: the existing one, else one
     inheriting every published chunk, else an empty file. A whole body is split
     into chunks first, since only chunks can be addressed by a partial write. *)
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
          let name =
            Filename.basename
              (Key.strip_prefix ~domain_prefix:C.domain_prefix key)
          in
          match published with
            | Some m ->
                {
                  Manifest.s_name = m.Manifest.name;
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

  (* Copy a whole body into per-chunk staged bodies, then drop it. *)
  and split_whole key (st : Manifest.staged) uuid =
    let* cs = R.chunk_size () in
    let total = Int64.to_int st.Manifest.s_size in
    let n = Manifest.num_chunks_for st.Manifest.s_size cs in
    let slots = Array.make n Manifest.Zero in
    let buf = Bigarray.Array1.create Bigarray.char Bigarray.c_layout cs in
    let rec chunk i =
      if i >= n then Lwt.return_unit
      else (
        let len = min cs (total - (i * cs)) in
        let slice = Bigarray.Array1.sub buf 0 len in
        let* (_ : int) =
          Cc.whole_read_into ~uuid slice ~offset:(Int64.of_int (i * cs))
        in
        let body = Manifest.new_uuid () in
        let* () = Cc.stage_empty ~uuid:body ~len in
        let* (_ : int) = Cc.stage_write ~uuid:body slice ~chunk_off:0 in
        slots.(i) <- Manifest.Staged body;
        chunk (i + 1))
    in
    let* () = chunk 0 in
    let st =
      { st with Manifest.s_slots = slots; s_chunk_size = cs; s_whole = None }
    in
    let* () = Mf.write_staged key st in
    Cc.whole_forget ~uuid

  let grow_slots slots n =
    let old = Array.length slots in
    if n <= old then slots
    else (
      let a = Array.make n Manifest.Zero in
      Array.blit slots 0 a 0 old;
      a)

  (* An inherited chunk is copied in only on a partial write, where its
     untouched bytes must survive; [full_cover] skips that read. *)
  let stage_slot ~base ~(st : Manifest.staged) ~full_cover i =
    let slots = st.Manifest.s_slots in
    let stage_sparse uuid =
      let len =
        Manifest.chunk_len ~size:st.Manifest.s_size
          ~chunk_size:st.Manifest.s_chunk_size i
      in
      let+ () = Cc.stage_empty ~uuid ~len in
      slots.(i) <- Manifest.Staged uuid
    in
    match slots.(i) with
      | Manifest.Staged _ -> Lwt.return_unit
      | Manifest.Inherit when not full_cover -> (
          let uuid = Manifest.new_uuid () in
          match Mf.group_at_opt base i with
            | Some group ->
                let+ () = Cc.stage_from_chunk ~group ~index:i ~uuid in
                slots.(i) <- Manifest.Staged uuid
            | None -> stage_sparse uuid)
      | Manifest.Inherit | Manifest.Zero -> stage_sparse (Manifest.new_uuid ())

  (* Stages the whole group [i] falls in, so a group is either untouched or
     wholly local — never a mix of staged bodies and chunks whose bytes only
     exist under the old group key the write invalidated. [covers j] reports a
     full overwrite of chunk [j], which costs no copy.
     ponytail: a one-byte write materializes up to [cacheChunkSize] of staged
     bodies; stage per member and assemble the remainder at promotion time if
     write amplification ever bites. *)
  let stage_group ~base ~(st : Manifest.staged) ~covers i =
    let per =
      Chunk_group.per_group ~chunk_size:st.Manifest.s_chunk_size
        ~cache_chunk_size
    in
    let n = Array.length st.Manifest.s_slots in
    let first = Chunk_group.index_of ~per i * per in
    let last = min (n - 1) (first + per - 1) in
    let rec go j =
      if j > last then Lwt.return_unit
      else
        let* () = stage_slot ~base ~st ~full_cover:(covers j) j in
        go (j + 1)
    in
    go first

  (* Bytes land before the staged manifest: a crash in between leaves an
     unreferenced body rather than a manifest pointing at unwritten bytes. *)
  let write key buf ~offset =
    let len = Bigarray.Array1.dim buf in
    let* st = staged_for key in
    let* base = Mf.read key in
    let base = match base with Some m -> Some m | _ -> None in
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
        let* () = stage_group ~base ~st ~covers i in
        let* () =
          match st.Manifest.s_slots.(i) with
            | Manifest.Staged uuid ->
                let src_off = (i * cs) + chunk_off - start in
                let slice = Bigarray.Array1.sub buf src_off take in
                let+ (_ : int) = Cc.stage_write ~uuid slice ~chunk_off in
                ()
            | Manifest.Inherit | Manifest.Zero ->
                (* [stage_slot] just made this a staged body. *)
                Lwt.fail_with "data: slot not staged"
        in
        go (i + 1))
    in
    let* () = go first in
    let st = { st with Manifest.s_mtime = Unix.gettimeofday () } in
    let+ () = Mf.write_staged key st in
    len

  (* A grow is pure metadata: new chunks are holes until written. *)
  let truncate key size =
    let* st = staged_for key in
    let* base = Mf.read key in
    let base = match base with Some m -> Some m | _ -> None in
    let cs = st.Manifest.s_chunk_size in
    let n = Manifest.num_chunks_for size cs in
    let old = st.Manifest.s_slots in
    let* () =
      let rec drop i =
        if i >= Array.length old then Lwt.return_unit
        else
          let* () =
            match old.(i) with
              | Manifest.Staged uuid -> Cc.stage_forget ~uuid
              | Manifest.Inherit | Manifest.Zero -> Lwt.return_unit
          in
          drop (i + 1)
      in
      drop n
    in
    let slots = grow_slots (Array.sub old 0 (min n (Array.length old))) n in
    let st = { st with Manifest.s_slots = slots; s_size = size } in
    let* () =
      let i = n - 1 in
      if i < 0 then Lwt.return_unit
      else (
        let len = Manifest.chunk_len ~size ~chunk_size:cs i in
        match slots.(i) with
          | Manifest.Staged uuid -> Cc.stage_truncate ~uuid ~len
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
                let* () = stage_group ~base ~st ~covers:(fun _ -> false) i in
                match slots.(i) with
                  | Manifest.Staged uuid -> Cc.stage_truncate ~uuid ~len
                  | Manifest.Inherit | Manifest.Zero -> Lwt.return_unit))
    in
    let st = { st with Manifest.s_mtime = Unix.gettimeofday () } in
    Mf.write_staged key st

  let discard_bodies (st : Manifest.staged) =
    let* () =
      Lwt_list.iter_s
        (fun slot ->
          match slot with
            | Manifest.Staged uuid -> Cc.stage_forget ~uuid
            | Manifest.Inherit | Manifest.Zero -> Lwt.return_unit)
        (Array.to_list st.Manifest.s_slots)
    in
    match st.Manifest.s_whole with
      | Some uuid -> Cc.whole_forget ~uuid
      | None -> Lwt.return_unit

  let create key =
    let* st = Mf.read_staged key in
    let* () =
      match st with Some st -> discard_bodies st | None -> Lwt.return_unit
    in
    let name =
      Filename.basename (Key.strip_prefix ~domain_prefix:C.domain_prefix key)
    in
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

  (* Bytes for chunk [i] in the form {!Remote.upload_chunks} wants: an inherited
     chunk keeps its published entry and is never re-sent, a hole hashes as zeros
     without touching disk, a staged body is padded to its chunk length. *)
  let staged_source ~(staged : Manifest.staged) ~base i =
    let cs = staged.Manifest.s_chunk_size in
    let len =
      Manifest.chunk_len ~size:staged.Manifest.s_size ~chunk_size:cs i
    in
    let slots = staged.Manifest.s_slots in
    if i >= Array.length slots then Lwt.return (`Data (String.make len '\000'))
    else (
      match slots.(i) with
        | Manifest.Zero -> Lwt.return (`Data (String.make len '\000'))
        | Manifest.Inherit -> (
            match base with
              | Some m when i < Chunk_table.count m.Manifest.chunks ->
                  Lwt.return (`Reuse (Chunk_table.key m.Manifest.chunks i))
              | Some _ | None ->
                  Lwt.fail
                    (Backend.Backend_error
                       (Printf.sprintf "staged chunk %d inherits nothing" i)))
        | Manifest.Staged uuid ->
            let+ body =
              Lwt.catch
                (fun () ->
                  Lwt_unix_retry.with_file ~mode:Lwt_io.Input
                    (Cc.staged_path uuid) Lwt_io.read)
                (fun _ -> Lwt.return "")
            in
            let have = String.length body in
            `Data
              (if have = len then body
               else if have > len then String.sub body 0 len
               else body ^ String.make (len - have) '\000'))

  (* Recording the published manifest inside the staged one is the commit point
     of the promotion below: after it, recovery replays the local moves instead
     of re-sending bytes. *)
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
    let base = match base with Some m -> Some m | _ -> None in
    let* state =
      R.upload_chunks ~key ~name:staged.Manifest.s_name
        ~size:staged.Manifest.s_size ~chunk_size:staged.Manifest.s_chunk_size
        ~mtime:staged.Manifest.s_mtime
        ~source:(staged_source ~staged ~base)
        ?cancel ()
    in
    commit key staged state

  (* Written before anything local moves. A crash before this re-uploads
     identical bytes; after it, only local moves are left to replay. *)
  and commit key (staged : Manifest.staged) published =
    let+ () =
      Mf.write_staged key { staged with Manifest.s_published = Some published }
    in
    published

  (* Every step is idempotent, so a crash anywhere replays. *)
  let rec promote key (staged : Manifest.staged) (published : Manifest.t) =
    match staged.Manifest.s_whole with
      | Some uuid ->
          (* The chunk store deliberately ends up holding none of this file's
             chunks: the only caller handing over whole files is the FileProvider
             extension, which keeps its own copy of everything it materialized.
             Caching the bytes again would double the disk cost of every edit;
             reads from elsewhere fetch like any other published file. *)
          let* () = Mf.write key published in
          let* () = Cc.whole_forget ~uuid in
          Mf.delete_staged key
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
       on disk. Anything else would come from the old, invalidated group key. *)
    let local group =
      List.for_all
        (fun i ->
          match slot_at i with
            | Manifest.Staged _ | Manifest.Zero -> true
            | Manifest.Inherit -> false)
        (Chunk_group.indices group)
    in
    (* Local-only: every member's bytes are already here. An untouched group
       keeps its key, so whatever body we hold for it is still right. *)
    let* () =
      Lwt_list.iter_s
        (fun group ->
          if touched group && local group then
            Cc.put_group ~group ~member:(fun i ->
                let+ source = staged_source ~staged ~base:None i in
                match source with
                  | `Data body -> body
                  | `Reuse _ -> assert false (* [local] ruled this out *))
          else Lwt.return_unit)
        (Mf.groups published)
    in
    let* () =
      Lwt_list.iter_s
        (fun slot ->
          match slot with
            | Manifest.Staged uuid -> Cc.stage_forget ~uuid
            | Manifest.Inherit | Manifest.Zero -> Lwt.return_unit)
        (Array.to_list slots)
    in
    let* () = Mf.write key published in
    Mf.delete_staged key

  (* A staged manifest already carrying a published one was interrupted
     mid-promotion: finish it without re-uploading. *)
  let sync key ?cancel () =
    let* staged = Mf.read_staged key in
    match staged with
      | None -> Lwt.return_unit
      | Some ({ Manifest.s_published = Some published; _ } as staged) ->
          promote key staged published
      | Some staged ->
          let* published = upload_staged ~key ~staged ?cancel () in
          promote key staged published

  (* Re-exported so a domain has exactly one {!Chunk_cache} instance: two would
     each keep their own in-flight table and stop deduplicating downloads. *)

  let enforce_chunk_cap = Cc.enforce_cap
  let chunk_stats = Cc.stats
  let downloads_in_flight = Cc.in_flight

  (* Adopts [src_path] by rename: no copy, no chunking pass; the upload reads it
     directly. *)
  let stage_whole key ~src_path =
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
        Manifest.s_name =
          Filename.basename
            (Key.strip_prefix ~domain_prefix:C.domain_prefix key);
        s_size = stat.Unix.LargeFile.st_size;
        s_mtime = stat.Unix.LargeFile.st_mtime;
        s_chunk_size = chunk_size;
        s_slots = [||];
        s_whole = Some uuid;
        s_published = None;
      }

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

  (* Progress of a file being made local, for a caller showing a bar. Advisory:
     absent means nothing is running for that key.

     [total] counts fetch *and* reassembly bytes, since both take real time on a
     large file and a bar that stops at the end of the fetch cannot be told from
     a hang. [holders] lets two materializations of one key share a row instead
     of the first to finish taking it away from the other. *)
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
     than one group only moves when it finishes. Per stored chunk would halve the
     step and no more, and {!Chunk_cache.ensure} hands a second caller the
     in-flight promise without its callback, so doing it properly needs a
     listener registry. Worth it only if the step is ever felt. *)
  let fetch_groups key groups =
    Lwt_list.iter_p
      (fun group ->
        let+ () = Cc.ensure ~group () in
        credit key (Chunk_group.bytes group))
      groups

  (* Counted here, not at the callers, so every route to a materialized file is
     included. *)
  let downloads_completed = ref 0
  let downloads_completed_count () = !downloads_completed

  (* Which groups [key] still owes the network, resolved up front so a caller
     can size a progress bar. [None] is "nothing to materialize", distinct from
     an empty list: a file with no chunks was still made local. *)
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

  (* {!assemble_to} for one range: everything outside it is left sparse, and
     only the chunks the range covers are fetched. Returns the byte count, short
     only at end of file. The file is created even for a range wholly past the
     end, since the caller is handed this path either way.

     ponytail: no progress span. A range is bounded by construction and its
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

  (* Unreference-blind by design: a chunk shared with another file goes too and
     is re-fetched on demand, which is what avoids refcounting. Staged bodies are
     never dropped, being the only copy of unsynced bytes. *)
  let forget_chunks key =
    let* published = Mf.read key in
    match published with
      | Some m -> Lwt_list.iter_s (fun group -> Cc.forget ~group) (Mf.groups m)
      | None -> Lwt.return_unit
end
