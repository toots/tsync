(* File content as bytes, served per chunk out of {!Chunk_cache}.

   A file is never assembled: a read maps its byte range onto the chunks that
   back it and copies out of each chunk body, fetching the ones that are absent.
   Nothing records which chunks are local — the chunk store answers that by
   existing — so there is no per-file state here beyond a read-ahead hint. *)

open Lwt.Syntax

(* Sequential reads pull the next window of chunks in the background, so the
   following read hits the disk. Off for random access. *)
let readahead_bytes = 4 * 1024 * 1024
let max_readahead_chunks = 8

module Make (C : Conf.S) (R : Remote.S) = struct
  module Cc = Chunk_cache.Make (C) (R)
  module Mf = Manifest.Make (C)

  (* End offset of the last read per id, the only signal for read-ahead. Purely
     advisory: a lost or stale entry costs at most one un-prefetched read. *)
  let last_read_end : (string, int) Hashtbl.t = Hashtbl.create 64

  (* Chunk entries by index. Manifests carry them as a list in index order, but
     the index field is authoritative. *)
  let entries_of (m : Manifest.t) =
    let n = List.length m.Manifest.chunks in
    let a = Array.make n None in
    List.iter
      (fun (c : Manifest.chunk_entry) ->
        if c.Manifest.index >= 0 && c.Manifest.index < n then
          a.(c.Manifest.index) <- Some c)
      m.Manifest.chunks;
    a

  let chunk_key_at entries i =
    match entries.(i) with
      | Some c -> Some (Manifest.chunk_key c)
      | None -> None

  let read_ahead entries ~chunk_size ~last =
    let n = Array.length entries in
    let window =
      min max_readahead_chunks (max 1 (readahead_bytes / max 1 chunk_size))
    in
    let hi = min (n - 1) (last + window) in
    if hi > last then
      Lwt.async (fun () ->
          Lwt.catch
            (fun () ->
              let rec go i =
                if i > hi then Lwt.return_unit
                else
                  let* () =
                    match chunk_key_at entries i with
                      | Some ck -> Cc.ensure ~chunk_key:ck ()
                      | None -> Lwt.return_unit
                  in
                  go (i + 1)
              in
              go (last + 1))
            (fun _ -> Lwt.return_unit))

  (* Read into [buf] from [offset] in the file described by [manifest]. [id]
     identifies the file for the read-ahead heuristic only. Returns the number of
     bytes read, short only at end of file. *)
  let pread ~id ~(manifest : Manifest.t) buf ~offset =
    let cs = manifest.Manifest.chunk_size in
    let size = manifest.Manifest.size in
    let want = Bigarray.Array1.dim buf in
    let start = Int64.to_int offset in
    let avail = Int64.to_int (Int64.sub size offset) in
    let total = min want (max 0 avail) in
    if total <= 0 || cs <= 0 || manifest.Manifest.chunks = [] then Lwt.return 0
    else (
      let entries = entries_of manifest in
      let n = Array.length entries in
      let rec go pos done_ =
        if done_ >= total then Lwt.return done_
        else (
          let i = pos / cs in
          if i >= n then Lwt.return done_
          else (
            let chunk_off = pos mod cs in
            let take = min (cs - chunk_off) (total - done_) in
            match chunk_key_at entries i with
              | None ->
                  (* A manifest whose chunk list has a hole is corrupt; refusing
                     is better than serving zeros as if they were content. *)
                  Lwt.fail
                    (Backend.Backend_error
                       (Printf.sprintf "manifest %s: missing chunk %d" id i))
              | Some ck ->
                  let slice = Bigarray.Array1.sub buf done_ take in
                  let* got = Cc.read_into ~chunk_key:ck slice ~chunk_off in
                  if got <= 0 then Lwt.return done_
                  else go (pos + got) (done_ + got)))
      in
      let* got = go start 0 in
      let last = min (n - 1) ((start + max 0 (got - 1)) / cs) in
      if Hashtbl.find_opt last_read_end id = Some start then
        read_ahead entries ~chunk_size:cs ~last;
      Hashtbl.replace last_read_end id (start + got);
      Lwt.return got)

  (* ── Staged reads ─────────────────────────────────────────────────────────── *)

  (* Read a range out of a staged file: from the whole body a frontend handed
     over, or else per chunk — from its staged body,
     from the published chunk it still inherits, or from nowhere at all (a hole
     from a grow, which reads as zeros). *)
  let rec pread_staged ~id ~(staged : Manifest.staged) ~base buf ~offset =
    match staged.Manifest.s_whole with
      | Some uuid ->
          (* One file: the range maps straight onto it, clipped to the size the
             staged manifest records. *)
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
      let inherited = match base with Some m -> entries_of m | None -> [||] in
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
                    (* A staged body is sparse: it is only as long as the writes
                       that reached it, so bytes past its end are a hole in the
                       chunk (a grow extended the file past what was written) and
                       read as zeros. *)
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
                    match
                      if i < Array.length inherited then
                        chunk_key_at inherited i
                      else None
                    with
                      | Some ck -> Cc.read_into ~chunk_key:ck slice ~chunk_off
                      | None ->
                          Lwt.fail
                            (Backend.Backend_error
                               (Printf.sprintf
                                  "staged %s: chunk %d inherits nothing" id i)))
            in
            if got <= 0 then Lwt.return done_ else go (pos + got) (done_ + got)))
      in
      go start 0)

  (* Read [key], whatever state it is in: staged edits, else what was published,
     else the backend's manifest for a file with no local metadata at all. *)
  let pread_key key buf ~offset =
    let* resolved = Mf.resolve key in
    match resolved with
      | Some (`Staged (staged, base)) ->
          pread_staged ~id:key ~staged ~base buf ~offset
      | Some (`Published m) -> pread ~id:key ~manifest:m buf ~offset
      | None -> (
          let* state = R.fetch_manifest ~key () in
          match state with
            | Some (`Clean m) -> pread ~id:key ~manifest:m buf ~offset
            | Some `Dirty | None -> Lwt.return 0)

  (* ── Writes ───────────────────────────────────────────────────────────────── *)

  (* The staged manifest a write starts from: the one already there, else one
     inheriting every chunk of the published manifest, else an empty file. A whole
     body is split into staged chunks first — chunks are what a partial write can
     address, and this is the only path that ever needs it (a frontend that hands
     over whole files never writes byte ranges). *)
  let rec staged_for key =
    let* st = Mf.read_staged key in
    match st with
      | Some ({ Manifest.s_whole = Some uuid; _ } as st) ->
          let* () = split_whole key st uuid in
          staged_for key
      | Some st -> Lwt.return st
      | None -> (
          let+ published = Mf.read key in
          let name =
            Filename.basename
              (Manifest.strip_prefix ~domain_prefix:C.domain_prefix key)
          in
          match published with
            | Some (`Clean m) ->
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
            | Some `Dirty | None ->
                {
                  Manifest.s_name = name;
                  s_size = 0L;
                  s_mtime = Unix.gettimeofday ();
                  s_chunk_size = C.chunk_size;
                  s_slots = [||];
                  s_whole = None;
                  s_published = None;
                })

  (* Copy a whole body into per-chunk staged bodies, then drop it. *)
  and split_whole key (st : Manifest.staged) uuid =
    let cs = C.chunk_size in
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

  (* Make slot [i] writable: a staged body already is, an inherited chunk is
     copied in when the write covers only part of it (its untouched bytes must
     survive), a hole becomes a sparse body. A write covering the whole chunk
     needs no prior bytes at all. *)
  let stage_slot ~base ~(st : Manifest.staged) ~full_cover i =
    let slots = st.Manifest.s_slots in
    match slots.(i) with
      | Manifest.Staged _ -> Lwt.return_unit
      | Manifest.Inherit when not full_cover -> (
          let uuid = Manifest.new_uuid () in
          let inherited =
            match base with Some m -> entries_of m | None -> [||]
          in
          match
            if i < Array.length inherited then chunk_key_at inherited i
            else None
          with
            | Some ck ->
                let+ () = Cc.stage_from_chunk ~chunk_key:ck ~uuid in
                slots.(i) <- Manifest.Staged uuid
            | None ->
                let+ () =
                  Cc.stage_empty ~uuid
                    ~len:
                      (Manifest.chunk_len ~size:st.Manifest.s_size
                         ~chunk_size:st.Manifest.s_chunk_size i)
                in
                slots.(i) <- Manifest.Staged uuid)
      | Manifest.Inherit | Manifest.Zero ->
          let uuid = Manifest.new_uuid () in
          let len =
            Manifest.chunk_len ~size:st.Manifest.s_size
              ~chunk_size:st.Manifest.s_chunk_size i
          in
          let+ () = Cc.stage_empty ~uuid ~len in
          slots.(i) <- Manifest.Staged uuid

  (* Write [buf] at [offset]. Bytes land before the staged manifest does: a crash
     in between leaves an unreferenced body (harmless) rather than a manifest
     pointing at bytes that were never written. *)
  let write key buf ~offset =
    let len = Bigarray.Array1.dim buf in
    let* st = staged_for key in
    let* base = Mf.read key in
    let base = match base with Some (`Clean m) -> Some m | _ -> None in
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
    let rec go i =
      if i > last then Lwt.return_unit
      else (
        let chunk_off = if i = first then start mod cs else 0 in
        let take =
          min (cs - chunk_off) (len - ((i * cs) + chunk_off - start))
        in
        let full_cover =
          chunk_off = 0
          && take >= Manifest.chunk_len ~size:new_size ~chunk_size:cs i
        in
        let* () = stage_slot ~base ~st ~full_cover i in
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

  (* Resize to [size]: drop whole chunks past the end, fix up the boundary chunk,
     and let a grow be pure metadata — new chunks are holes until written. *)
  let truncate key size =
    let* st = staged_for key in
    let* base = Mf.read key in
    let base = match base with Some (`Clean m) -> Some m | _ -> None in
    let cs = st.Manifest.s_chunk_size in
    let n = Manifest.num_chunks_for size cs in
    let old = st.Manifest.s_slots in
    (* Bodies past the new end are unreferenced from here on. *)
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
    (* The last chunk's length changes, so its body must be resized to match. *)
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
                let* () = stage_slot ~base ~st ~full_cover:false i in
                match slots.(i) with
                  | Manifest.Staged uuid -> Cc.stage_truncate ~uuid ~len
                  | Manifest.Inherit | Manifest.Zero -> Lwt.return_unit))
    in
    let st = { st with Manifest.s_mtime = Unix.gettimeofday () } in
    Mf.write_staged key st

  (* A brand-new (or O_TRUNC'd) file: no base, no bodies, size zero. *)
  (* Every body a staged manifest references, unreferenced from here on. *)
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
      Filename.basename
        (Manifest.strip_prefix ~domain_prefix:C.domain_prefix key)
    in
    Mf.write_staged key
      {
        Manifest.s_name = name;
        s_size = 0L;
        s_mtime = Unix.gettimeofday ();
        s_chunk_size = C.chunk_size;
        s_slots = [||];
        s_whole = None;
        s_published = None;
      }

  (* ── Upload and promotion ─────────────────────────────────────────────────── *)

  (* Bytes for chunk [i] of a staged file, in the form {!Remote.upload_chunks}
     wants: an inherited chunk keeps its published entry (never read, never
     re-sent), a hole hashes as zeros without touching disk, and a staged body is
     read padded to its chunk length — it is only as long as the writes that
     reached it. *)
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
            let inherited =
              match base with Some m -> entries_of m | None -> [||]
            in
            match
              if i < Array.length inherited then inherited.(i) else None
            with
              | Some e -> Lwt.return (`Reuse e)
              | None ->
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

  (* Upload [key]'s staged edits and publish its manifest, then record what was
     published *in the staged manifest itself*. That write is the commit point of
     the promotion below: after it, no crash can cost us the upload — recovery
     replays the local moves instead of re-sending bytes. *)
  let rec upload_staged ~key ~(staged : Manifest.staged) ?cancel () =
    match staged.Manifest.s_whole with
      | Some uuid ->
          (* A whole file needs no per-chunk source: hand the file itself to the
             ordinary whole-file upload, which reads, hashes and sends it. *)
          let* state =
            R.upload ~key ~src_path:(Cc.whole_path uuid)
              ~mtime:staged.Manifest.s_mtime ~chunk_size:C.chunk_size ?cancel ()
          in
          commit key staged state
      | None -> upload_chunked ~key ~staged ?cancel ()

  and upload_chunked ~key ~(staged : Manifest.staged) ?cancel () =
    let* base = Mf.read key in
    let base = match base with Some (`Clean m) -> Some m | _ -> None in
    let* state =
      R.upload_chunks ~key ~name:staged.Manifest.s_name
        ~size:staged.Manifest.s_size ~chunk_size:staged.Manifest.s_chunk_size
        ~mtime:staged.Manifest.s_mtime
        ~source:(staged_source ~staged ~base)
        ?cancel ()
    in
    commit key staged state

  (* The commit record: what was published, written into the staged manifest
     before anything local moves. A crash before this re-uploads (identical bytes,
     identical manifest); after it, only local moves are left to replay. *)
  and commit key (staged : Manifest.staged) state =
    match state with
      | `Clean published ->
          let+ () =
            Mf.write_staged key
              { staged with Manifest.s_published = Some published }
          in
          published
      | `Dirty -> Lwt.fail_with "data: upload published a dirty manifest"

  (* Finish a committed upload: move each staged body under the content key its
     bytes hashed to, replace the sidecar with what was published, then drop the
     staged manifest. Every step is idempotent, so a crash anywhere replays. *)
  let rec promote key (staged : Manifest.staged) (published : Manifest.t) =
    match staged.Manifest.s_whole with
      | Some uuid ->
          (* The upload hashed and sent the chunks straight from the whole file, so
             there is nothing to rename into the chunk store: promotion publishes
             the sidecar and drops the file, and the store ends up holding none of
             this file's chunks.

             That is deliberate. The only caller handing over whole files is the
             FileProvider extension, which keeps its own copy of every file it has
             materialized — caching the same bytes a second time here would double
             the disk cost of every edit for nothing. A read that does come our way
             (a share, an export, a peer) fetches what it needs like any other
             published file. Splitting the file into chunk bodies instead would
             cost a full extra copy of it on every single write. *)
          let* () = Mf.write key (`Clean published) in
          let* () = Cc.whole_forget ~uuid in
          Mf.delete_staged key
      | None -> promote_chunked key staged published

  and promote_chunked key (staged : Manifest.staged) (published : Manifest.t) =
    let entries = entries_of published in
    let* () =
      Lwt_list.iteri_s
        (fun i slot ->
          match slot with
            | Manifest.Staged uuid -> (
                match
                  if i < Array.length entries then chunk_key_at entries i
                  else None
                with
                  | Some chunk_key -> Cc.promote ~uuid ~chunk_key
                  | None -> Cc.stage_forget ~uuid)
            | Manifest.Inherit | Manifest.Zero -> Lwt.return_unit)
        (Array.to_list staged.Manifest.s_slots)
    in
    let* () = Mf.write key (`Clean published) in
    Mf.delete_staged key

  (* Upload [key] if it owes one, then promote. A staged manifest that already
     carries a published manifest was interrupted mid-promotion: finish it
     without re-uploading. *)
  let sync key ?cancel () =
    let* staged = Mf.read_staged key in
    match staged with
      | None -> Lwt.return_unit
      | Some ({ Manifest.s_published = Some published; _ } as staged) ->
          promote key staged published
      | Some staged ->
          let* published = upload_staged ~key ~staged ?cancel () in
          promote key staged published

  (* ── Chunk store housekeeping ─────────────────────────────────────────────
     Exposed through here so a domain has exactly one {!Chunk_cache} instance:
     two would each keep their own in-flight table and stop deduplicating each
     other's downloads. *)

  let enforce_chunk_cap = Cc.enforce_cap
  let chunk_stats = Cc.stats
  let downloads_in_flight = Cc.in_flight

  (* Take a whole file handed over by a frontend (the FileProvider extension
     always gives back a complete file, never a delta) as [key]'s new content.
     The file is adopted where it is — a rename, no copy and no chunking pass —
     and the upload reads it directly. *)
  let stage_whole key ~src_path =
    let* st = Mf.read_staged key in
    let* () =
      match st with Some st -> discard_bodies st | None -> Lwt.return_unit
    in
    let* stat = Lwt_unix_retry.LargeFile.stat src_path in
    let uuid = Manifest.new_uuid () in
    (* Bytes first, then the manifest that references them. *)
    let* () = Cc.adopt_whole ~src:src_path ~uuid in
    Mf.write_staged key
      {
        Manifest.s_name =
          Filename.basename
            (Manifest.strip_prefix ~domain_prefix:C.domain_prefix key);
        s_size = stat.Unix.LargeFile.st_size;
        s_mtime = stat.Unix.LargeFile.st_mtime;
        s_chunk_size = C.chunk_size;
        s_slots = [||];
        s_whole = Some uuid;
        s_published = None;
      }

  (* How much of [key] is local: (chunks present, chunks total). Staged bodies
     count as present — they are the newest bytes there are. *)
  let chunk_residency key =
    let* resolved = Mf.resolve key in
    match resolved with
      | None -> Lwt.return (0, 0)
      | Some (`Published m) ->
          let entries = entries_of m in
          let total = Array.length entries in
          let+ present =
            Lwt_list.fold_left_s
              (fun acc i ->
                match chunk_key_at entries i with
                  | None -> Lwt.return acc
                  | Some ck ->
                      let+ here = Cc.exists ck in
                      if here then acc + 1 else acc)
              0 (List.init total Fun.id)
          in
          (present, total)
      | Some (`Staged (({ Manifest.s_whole = Some _; _ } as st), _)) ->
          (* One file, every byte of it here. *)
          let n =
            Manifest.num_chunks_for st.Manifest.s_size st.Manifest.s_chunk_size
          in
          Lwt.return (n, n)
      | Some (`Staged (st, base)) ->
          let inherited =
            match base with Some m -> entries_of m | None -> [||]
          in
          let slots = st.Manifest.s_slots in
          let total = Array.length slots in
          let+ present =
            Lwt_list.fold_left_s
              (fun acc i ->
                match slots.(i) with
                  | Manifest.Staged _ | Manifest.Zero -> Lwt.return (acc + 1)
                  | Manifest.Inherit -> (
                      match
                        if i < Array.length inherited then
                          chunk_key_at inherited i
                        else None
                      with
                        | Some ck ->
                            let+ here = Cc.exists ck in
                            if here then acc + 1 else acc
                        | None -> Lwt.return acc))
              0 (List.init total Fun.id)
          in
          (present, total)

  (* ── Whole-file materialization ───────────────────────────────────────────── *)

  (* Per-key (bytes fetched, bytes to fetch) while a whole file is being pulled
     in, for the FileProvider's progress bar. Advisory only: absent means no
     materialization is running. *)
  let active : (string, int * int) Hashtbl.t = Hashtbl.create 8
  let download_progress key = Hashtbl.find_opt active key

  let entry_size entries i =
    match entries.(i) with
      | Some (c : Manifest.chunk_entry) -> c.Manifest.size
      | None -> 0

  (* Fetch the named chunks, tracking progress. [R.get_chunk] is pool-bounded, so
     asking for a whole file at once cannot exceed [max_downloads]. *)
  let ensure_entries key entries indices =
    let total =
      List.fold_left (fun acc i -> acc + entry_size entries i) 0 indices
    in
    Hashtbl.replace active key (0, total);
    Lwt.finalize
      (fun () ->
        Lwt_list.iter_p
          (fun i ->
            match chunk_key_at entries i with
              | None -> Lwt.return_unit
              | Some ck -> (
                  let+ () = Cc.ensure ~chunk_key:ck () in
                  match Hashtbl.find_opt active key with
                    | Some (done_, total) ->
                        Hashtbl.replace active key
                          (done_ + entry_size entries i, total)
                    | None -> ()))
          indices)
      (fun () ->
        Hashtbl.remove active key;
        Lwt.return_unit)

  (* Pull every chunk [key] needs into the store, so a later read is served
     without the network: what a restore asks for. Staged bodies are already
     local, so only the chunks a file still inherits are fetched. A file with no
     local metadata gets its sidecar written first, otherwise the restore leaves
     nothing behind for the read path to resolve. *)
  let ensure_local key =
    let ensure_entries = ensure_entries key in
    let ensure_published (m : Manifest.t) =
      let entries = entries_of m in
      ensure_entries entries (List.init (Array.length entries) Fun.id)
    in
    let* resolved = Mf.resolve key in
    match resolved with
      | Some (`Published m) -> ensure_published m
      | Some (`Staged (st, base)) -> (
          match base with
            | None -> Lwt.return_unit
            | Some m ->
                let entries = entries_of m in
                let slots = st.Manifest.s_slots in
                ensure_entries entries
                  (List.init (Array.length slots) Fun.id
                  |> List.filter (fun i ->
                      slots.(i) = Manifest.Inherit && i < Array.length entries)
                  ))
      | None -> (
          let* state = R.fetch_manifest ~key () in
          match state with
            | Some (`Clean m) ->
                let* () = Mf.write key (`Clean m) in
                ensure_published m
            | Some `Dirty | None -> Lwt.return_unit)

  (* Write [key]'s whole content to [dst_path]: the one way a caller that needs a
     real file (export, or the file handed to the FileProvider extension) gets
     one. It goes through the ordinary read path, so staged edits, inherited
     chunks and holes all come out right and the chunk store is populated on the
     way. *)
  let assemble_to key ~dst_path =
    let* () = Fs_util.ensure_parent dst_path in
    let* () = ensure_local key in
    let buf =
      Bigarray.Array1.create Bigarray.char Bigarray.c_layout C.chunk_size
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
        go (Int64.add offset (Int64.of_int n))
    in
    let* () = go 0L in
    (* Publish the file's own mtime: an export or a handoff copy should look like
       the file it came from, not like the moment it was written. *)
    let* resolved = Mf.resolve key in
    match resolved with
      | Some (`Staged (st, _)) ->
          Lwt_unix_retry.utimes dst_path st.Manifest.s_mtime st.Manifest.s_mtime
      | Some (`Published m) ->
          Lwt_unix_retry.utimes dst_path m.Manifest.mtime m.Manifest.mtime
      | None -> Lwt.return_unit

  (* Drop [key]'s locally cached chunks. Unreference-blind by design: a chunk
     shared with another file goes too and is re-fetched on demand — refcounting
     is exactly the bookkeeping this design removes. Staged bodies are never
     dropped; they are the only copy of unsynced bytes. *)
  let forget_chunks key =
    let* published = Mf.read key in
    match published with
      | Some (`Clean m) ->
          Lwt_list.iter_s
            (fun (c : Manifest.chunk_entry) ->
              Cc.forget ~chunk_key:(Manifest.chunk_key c))
            m.Manifest.chunks
      | Some `Dirty | None -> Lwt.return_unit
end
