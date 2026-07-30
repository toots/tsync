open Lwt.Syntax

(* A composite Backend.S that wraps the authoritative backends and lazily fills
   one or more *backfill* targets from the write side.

   A backfill target is a converging copy, not a replica: it is never read from,
   it never blocks a foreground write, and it never fails one.

   The role exists for the case where copying the data already in the source of
   truth is impractical or not worth doing — a very large dataset, a metered link,
   an archive tier where insuring everything costs more than the data is worth. So
   the target starts empty and covers only what is written from then on. What makes
   that useful rather than merely incomplete is *partial coverage, never partial
   files*: whatever the target does hold is whole and restorable on its own.
   Missing means a whole file is missing — never half of one, and never a manifest
   naming chunks that were never copied. Coverage only ever grows, so the active
   set converges over time while cold data nothing touches again is never copied.

   What it gets:

   - chunk PUTs, forwarded in the background — best-effort, deduped, and dropped
     outright when too many are already in flight.
   - manifest PUTs (and folder/trash markers, share manifests — anything that is
     not a chunk), queued in order. Before the PUT, every chunk key the body
     names is confirmed present on the target: HEAD, and on a miss fetch the
     bytes from the authoritative backend and PUT them. The manifest lands only
     after all of them, so the target never holds a manifest referencing chunks
     it does not have.
   - copies (a rename's copy+delete, a version snapshot) and deletes, in order.
   - nothing under [skip_prefixes] — the journal and the cursor are sync
     bookkeeping, not content.

   Correctness rests entirely on the manifest step, which is why dropping a
   chunk forward is safe: the chunk lane only saves the manifest job a fetch.
   That matters because the dedup in [Remote.chunk_exists] means a file copy or
   an incremental re-upload issues *no* chunk PUTs at all — just a manifest.

   Ordering is why the metadata lane is a queue and not N independent async
   jobs: [Store.copy_manifest] renames with a copy immediately followed by a
   delete of the source, and running those out of order would lose the file on
   the target. Chunks need no ordering — they are content-addressed.

   ponytail: the queue is in memory, so a daemon exit loses what is pending. That
   and closing the gap on purpose are both
   [tsync resync-remote --source <authoritative>]. Not filling a target with what
   predates it is the point of the role, not a shortcoming of this module. *)

type sub = { name : string; backend : (module Backend.S) }
type lane_stats = { queued : int; in_flight : int; degraded : bool }

type job =
  | Put of string * string
  | Copy of string * string
  | Delete of string
  | Delete_multi of string list

type lane = {
  name : string;
  target : (module Backend.S);
  jobs : job Queue.t;
  wake : unit Lwt_condition.t;
  settled : unit Lwt_condition.t;
  mutable idle : bool;
  mutable chunks_in_flight : int;
  (* Keys known present on the target: skips a HEAD per chunk, and is what makes
     a copy of an already-filled file nearly free. *)
  ensured : (string, unit) Hashtbl.t;
  mutable degraded : bool;
}

(* Concurrent chunk forwards. Past this, a chunk PUT is dropped rather than held
   in memory — the manifest job fetches it later. *)
let max_chunks_in_flight = 32

(* Queued metadata jobs. Past this the target is declared degraded and jobs are
   dropped; a queue this deep means the target cannot keep up at all. *)
let max_queued = 10_000

(* ponytail: crude memo — reset the whole table past the cap rather than keeping
   an LRU. 100k keys is a few MB, and overflowing costs only a HEAD per chunk
   again. Per-key eviction if the extra HEADs ever show up in a profile. *)
let max_ensured = 100_000

let remember t key =
  if Hashtbl.length t.ensured >= max_ensured then Hashtbl.reset t.ensured;
  Hashtbl.replace t.ensured key ()

(* Settled = nothing queued, the worker parked, no chunk in flight. *)
let rec settle t =
  if Queue.is_empty t.jobs && t.idle && t.chunks_in_flight = 0 then
    Lwt.return_unit
  else
    let* () = Lwt_condition.wait t.settled in
    settle t

let lanes : lane list ref = ref []

(* A target that has gone away must not hold a command open forever; giving up
   and saying so beats hanging. resync-remote is the repair. *)
let drain_timeout = 60.

let drain_all () =
  if !lanes = [] then Lwt.return_unit
  else
    Lwt.pick
      [
        Lwt_list.iter_p settle !lanes;
        (let* () = Lwt_unix.sleep drain_timeout in
         Log.err
           "backfill: still behind after %.0fs, giving up — run tsync \
            resync-remote"
           drain_timeout;
         Lwt.return_unit);
      ]

(* [inners]: the authoritative backends — the head serves every read, a write
     fans out to all of them, which is exactly what [Backends.Make] states.
   [chunk_keys]: the bare ["<h1>-<h2>"] keys a manifest body names, and [[]] for
     a body that is not a manifest. Injected so this library stays below
     [Chunk_table].
   [skip_prefixes]: keys never forwarded to a target. *)
type t = {
  backend : (module Backend.S);
  lanes : (string * (unit -> lane_stats)) list;
}

let make ~chunk_prefix ~(chunk_keys : string -> string list) ~skip_prefixes
    ~(inners : (module Backend.S) list) ~(backfills : sub list) : t =
  let (module Pri : Backend.S) =
    match inners with b :: _ -> b | [] -> failwith "no backends configured"
  in
  let is_chunk key = String.starts_with ~prefix:chunk_prefix key in
  let skipped key =
    List.exists (fun p -> String.starts_with ~prefix:p key) skip_prefixes
  in
  let ensure_chunk t chunk_key =
    let key = chunk_prefix ^ Chunk_layout.relative_path chunk_key in
    if Hashtbl.mem t.ensured key then Lwt.return_unit
    else
      let module T = (val t.target : Backend.S) in
      let* head = T.head_opt ~key () in
      let* () =
        match head with
          | Some _ -> Lwt.return_unit
          | None ->
              let* data = Pri.get ~key () in
              T.put ~key ~data ()
      in
      remember t key;
      Lwt.return_unit
  in
  let rec run t job =
    let module T = (val t.target : Backend.S) in
    match job with
      | Put (key, data) ->
          let* () = Lwt_list.iter_s (ensure_chunk t) (chunk_keys data) in
          T.put ~key ~data ()
      | Copy (src, dst) ->
          Lwt.catch
            (fun () -> T.copy ~src_key:src ~dst_key:dst ())
            (fun _ ->
              (* The target has no [src] — added after it was written, or its job
                 was dropped. The authoritative [dst] exists by now, so rebuild
                 from that instead, chunk check included. *)
              let* data = Pri.get_opt ~key:dst () in
              match data with
                | None -> Lwt.return_unit
                | Some data -> run t (Put (dst, data)))
      | Delete key ->
          Hashtbl.remove t.ensured key;
          T.delete ~key ()
      | Delete_multi keys ->
          List.iter (fun k -> Hashtbl.remove t.ensured k) keys;
          T.delete_multi keys
  in
  (* One sequential worker per target: order is the point, and a target that
     stalls must not stall the others. A failed job is dropped rather than
     retried — retrying at the head would block every later rename behind it. *)
  let rec worker t =
    if Queue.is_empty t.jobs then begin
      t.idle <- true;
      Lwt_condition.broadcast t.settled ();
      let* () = Lwt_condition.wait t.wake in
      worker t
    end
    else begin
      t.idle <- false;
      let job = Queue.pop t.jobs in
      let* () =
        Lwt.catch
          (fun () -> run t job)
          (fun exn ->
            Log.err "backfill %s: %s (dropped; run tsync resync-remote)" t.name
              (Printexc.to_string exn);
            Lwt.return_unit)
      in
      Lwt_condition.broadcast t.settled ();
      worker t
    end
  in
  let enqueue t job =
    if Queue.length t.jobs >= max_queued then begin
      if not t.degraded then begin
        t.degraded <- true;
        Log.err
          "backfill %s: %d jobs queued, dropping writes — it will need tsync \
           resync-remote"
          t.name max_queued
      end
    end
    else begin
      t.degraded <- false;
      Queue.push job t.jobs;
      Lwt_condition.broadcast t.wake ()
    end
  in
  let forward_chunk t key data =
    if Hashtbl.mem t.ensured key || t.chunks_in_flight >= max_chunks_in_flight
    then ()
    else begin
      t.chunks_in_flight <- t.chunks_in_flight + 1;
      Lwt.async (fun () ->
          Lwt.finalize
            (fun () ->
              Lwt.catch
                (fun () ->
                  let module T = (val t.target : Backend.S) in
                  let+ () = T.put ~key ~data () in
                  remember t key)
                (fun exn ->
                  Log.warn "backfill %s chunk %s: %s" t.name key
                    (Printexc.to_string exn);
                  Lwt.return_unit))
            (fun () ->
              t.chunks_in_flight <- t.chunks_in_flight - 1;
              Lwt_condition.broadcast t.settled ();
              Lwt.return_unit))
    end
  in
  let targets =
    List.map
      (fun (s : sub) ->
        let t =
          {
            name = s.name;
            target = s.backend;
            jobs = Queue.create ();
            wake = Lwt_condition.create ();
            settled = Lwt_condition.create ();
            idle = true;
            chunks_in_flight = 0;
            ensured = Hashtbl.create 1024;
            degraded = false;
          }
        in
        Lwt.async (fun () -> worker t);
        t)
      backfills
  in
  if !lanes = [] && targets <> [] then Backend.on_drain drain_all;
  lanes := !lanes @ targets;
  let fill key f = if not (skipped key) then List.iter f targets in
  let write f = Lwt_list.iter_s f inners in
  let lanes =
    List.map
      (fun t ->
        ( t.name,
          fun () ->
            {
              queued = Queue.length t.jobs;
              in_flight = t.chunks_in_flight;
              degraded = t.degraded;
            } ))
      targets
  in
  let backend : (module Backend.S) =
    (module struct
      let put ~key ~data () =
        let* () = write (fun (module B : Backend.S) -> B.put ~key ~data ()) in
        fill key (fun t ->
            if is_chunk key then forward_chunk t key data
            else enqueue t (Put (key, data)));
        Lwt.return_unit

      let delete ~key () =
        let* () = write (fun (module B : Backend.S) -> B.delete ~key ()) in
        fill key (fun t -> enqueue t (Delete key));
        Lwt.return_unit

      let delete_multi keys =
        let* () = write (fun (module B : Backend.S) -> B.delete_multi keys) in
        let keys = List.filter (fun k -> not (skipped k)) keys in
        if keys <> [] then
          List.iter (fun t -> enqueue t (Delete_multi keys)) targets;
        Lwt.return_unit

      let copy ~src_key ~dst_key () =
        let* () =
          write (fun (module B : Backend.S) -> B.copy ~src_key ~dst_key ())
        in
        fill dst_key (fun t -> enqueue t (Copy (src_key, dst_key)));
        Lwt.return_unit

      (* Reads never touch a backfill target: it is behind by construction. *)
      let get ~key () = Pri.get ~key ()
      let get_opt ~key () = Pri.get_opt ~key ()
      let head_opt ~key () = Pri.head_opt ~key ()

      let list_prefix ?max_keys ~prefix () =
        Pri.list_prefix ?max_keys ~prefix ()

      (* First authoritative backend with an opinion. *)
      let share_url ~prefix () =
        let rec go = function
          | [] -> Lwt.return_none
          | (module B : Backend.S) :: rest -> (
              let* u = B.share_url ~prefix () in
              match u with Some _ -> Lwt.return u | None -> go rest)
        in
        go inners

      let default_chunk_size ~prefix () =
        let rec go = function
          | [] -> Lwt.return_none
          | (module B : Backend.S) :: rest -> (
              let* n = B.default_chunk_size ~prefix () in
              match n with Some _ -> Lwt.return n | None -> go rest)
        in
        go inners
    end)
  in
  { backend; lanes }
