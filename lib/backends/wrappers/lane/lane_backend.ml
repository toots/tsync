open Lwt.Syntax

(* A composite Backend.S wrapping the authoritative backends and filling one or
   more targets from the write side, behind the write rather than in it.

   A write returns once the mains have it. Each target then catches up on its own
   lane, so a slow, metered or unreachable store never sets the pace of a copy
   into the mount. Two roles ride on that:

   - [replica] — a full second copy, and read from when no main is reachable. It
     must converge, so its lane is durable and never gives up on a failure that
     can clear.
   - [backfill] — a converging copy that starts empty and covers what is written
     from then on, never read from. For when copying what the mains already hold
     is impractical: a very large dataset whose full integrity is a
     nice-to-have. It gives {i partial coverage, never partial files}.

   What a target gets:

   - chunk PUTs, forwarded in the background: best-effort, deduped, and dropped
     outright when too many are in flight.
   - every other PUT (a manifest, a folder or trash marker, a share, a journal
     entry), queued in order. Every chunk key the body names is confirmed present
     first (HEAD, then fetch-and-PUT on a miss), so the target never holds a
     manifest referencing chunks it lacks.
   - copies (a rename's copy+delete, a version snapshot) and deletes, in order.
   - nothing under a lane's [skip_prefixes]: a backfill target has no use for the
     journal and cursor, and a replica needs both.

   Correctness rests entirely on the manifest step, which is why dropping a chunk
   forward is safe — the chunk lane only saves the manifest job a fetch. That
   matters because the dedup in [Remote.chunk_exists] means a file copy or an
   incremental re-upload issues no chunk PUTs at all. It is also why the durable
   log holds one record per user-visible operation rather than one per chunk.

   Ordering is why the metadata lane is a queue rather than N async jobs:
   [Store.copy_manifest] renames with a copy immediately followed by a delete of
   the source, and running those out of order loses the file on the target.
   Chunks are content-addressed and need no ordering.

   A queued job names a key and never carries a body: the worker re-reads from
   the mains when it runs the job. That is what makes the queue small enough to
   keep on disk, and it means a job always writes the current body — repeated
   puts to one key converge on the latest, and a put whose key has since been
   deleted reads back nothing and is skipped, its delete being queued behind it.

   The queue survives a restart, so an offline target catches up when the link
   comes back rather than needing [tsync resync-remote --source <main>]. Resync
   remains the repair for a target that was dropped work (see [degraded]), and
   the initial fill for one added to an existing domain — not filling a target
   with what predates it is the point of the backfill role, not a shortcoming. *)

type sub = {
  name : string;
  backend : (module Backend.S);
  skip_prefixes : string list;
}

type lane_stats = { queued : int; in_flight : int; degraded : bool }

(* Bodyless on purpose: see the header. *)
type job =
  | Put of string
  | Copy of string * string
  | Delete of string
  | Delete_multi of string list

(* A queued job and the log file that holds it, unlinked once the target has
   taken it. *)
type entry = { id : string; job : job }

type lane = {
  name : string;
  target : (module Backend.S);
  skip_prefixes : string list;
  dir : string;
  jobs : entry Queue.t;
  wake : unit Lwt_condition.t;
  settled : unit Lwt_condition.t;
  (* Held across recording one job, so the queue ends up in the order the ids
     say. Without it two concurrent writes can be named in one order and queued
     in the other, and a rename replayed backwards loses the file. *)
  recording : Lwt_mutex.t;
  mutable idle : bool;
  mutable seq : int;
  mutable failures : int;
  mutable chunks_in_flight : int;
  (* Skips a HEAD per chunk, which is what makes a copy of an already-filled file
     nearly free. *)
  ensured : (string, unit) Hashtbl.t;
  mutable degraded : bool;
}

(* Past this, a chunk PUT is dropped rather than held in memory: the manifest job
   fetches it later. *)
let max_chunks_in_flight = 32

(* Past this the target is declared degraded and jobs are dropped. A job is a
   short line on disk, so this is a runaway backstop rather than a memory bound:
   reaching it means the target has not kept up for a very long time. *)
let max_queued = 100_000

(* ponytail: crude memo — reset the whole table past the cap rather than keeping
   an LRU. 100k keys is a few MB, and overflowing costs only a HEAD per chunk
   again. Per-key eviction if the extra HEADs ever show up in a profile. *)
let max_ensured = 100_000

let remember t key =
  if Hashtbl.length t.ensured >= max_ensured then Hashtbl.reset t.ensured;
  Hashtbl.replace t.ensured key ()

(* Settled = nothing queued, the worker parked, no chunk in flight.

   A target that has started failing ends the wait too. What it still owes is on
   disk and outlives the process, so holding a command open for a store that is
   down buys nothing — where before durability there was nothing to come back
   to. *)
let rec settle t =
  if Queue.is_empty t.jobs && t.idle && t.chunks_in_flight = 0 then
    Lwt.return_unit
  else if t.failures > 0 then begin
    Log.warn "lane %s: target is down, leaving %d job(s) queued on disk" t.name
      (Queue.length t.jobs);
    Lwt.return_unit
  end
  else
    let* () = Lwt_condition.wait t.settled in
    settle t

let lanes : lane list ref = ref []

(* A target that is merely slow must not hold a command open forever either. What
   is queued is on disk, so the daemon picks it up on its next start. *)
let drain_timeout = 60.

let drain_all () =
  if !lanes = [] then Lwt.return_unit
  else
    Lwt.pick
      [
        Lwt_list.iter_p settle !lanes;
        (let* () = Lwt_unix.sleep drain_timeout in
         Log.warn
           "lane: still behind after %.0fs, leaving the rest queued on disk"
           drain_timeout;
         Lwt.return_unit);
      ]

(* {1 The durable log} *)

let job_to_json = function
  | Put key -> `Assoc [("op", `String "put"); ("key", `String key)]
  | Copy (src, dst) ->
      `Assoc
        [("op", `String "copy"); ("src", `String src); ("dst", `String dst)]
  | Delete key -> `Assoc [("op", `String "delete"); ("key", `String key)]
  | Delete_multi keys ->
      `Assoc
        [
          ("op", `String "delete_multi");
          ("keys", `List (List.map (fun k -> `String k) keys));
        ]

let job_of_json json =
  let open Yojson.Basic.Util in
  match json |> member "op" |> to_string with
    | "put" -> Some (Put (json |> member "key" |> to_string))
    | "copy" ->
        Some
          (Copy
             ( json |> member "src" |> to_string,
               json |> member "dst" |> to_string ))
    | "delete" -> Some (Delete (json |> member "key" |> to_string))
    | "delete_multi" ->
        Some
          (Delete_multi (json |> member "keys" |> to_list |> List.map to_string))
    | _ -> None
    | exception _ -> None

(* A lane's directory is named after the backend, which is whatever the config
   says. Anything outside the safe set becomes [%XX] so a name with a slash in it
   cannot climb out of the log root. Not reversed anywhere: the name is only ever
   written. *)
let escape name =
  let buf = Buffer.create (String.length name) in
  String.iter
    (fun c ->
      match c with
        | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' ->
            Buffer.add_char buf c
        | c -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)))
    name;
  Buffer.contents buf

(* Fixed-width microseconds first, so the directory's lexicographic order is
   chronological, then a counter for two jobs within one microsecond and the pid
   to keep two processes apart. More than one writes here: the daemon forks a
   process per frontend, and a one-shot command records what it does too. A plain
   counter would have them name different jobs the same file, and one would
   silently replace the other. *)
let id_of t =
  t.seq <- t.seq + 1;
  Printf.sprintf "%020Ld-%08d-%d"
    (Int64.of_float (Unix.gettimeofday () *. 1e6))
    t.seq (Unix.getpid ())

let path t id = Filename.concat t.dir id

(* The job is on disk before the caller is told the write is done. Recorded in
   the put path rather than in the background, since a job only queued in memory
   is one a crash loses without anything left saying it was owed. *)
let record t job =
  if Queue.length t.jobs >= max_queued then begin
    if not t.degraded then begin
      t.degraded <- true;
      Log.err
        "lane %s: %d jobs queued, dropping writes — it will need tsync \
         resync-remote"
        t.name max_queued
    end;
    Lwt.return_unit
  end
  else
    Lwt_mutex.with_lock t.recording (fun () ->
        let id = id_of t in
        let* () = Fs_util.mkdir_p t.dir in
        let+ () =
          Fs_util.atomic_write (path t id)
            (Yojson.Basic.to_string (job_to_json job))
        in
        Queue.push { id; job } t.jobs;
        Lwt_condition.broadcast t.wake ())

let forget t (e : entry) = Fs_util.unlink_quiet (path t e.id)

(* Everything the last run left owed, in the order it was recorded. Under the
   same lock as {!record}, so a write arriving while this runs queues behind what
   it finds rather than ahead of it. *)
let load t =
  Lwt_mutex.with_lock t.recording @@ fun () ->
  let* exists = Lwt_unix_retry.file_exists t.dir in
  if not exists then Lwt.return_unit
  else
    let* names = Fs_util.readdir_list t.dir in
    (* A job id leads with its timestamp; anything else is somebody's temp file,
       possibly a live one in another process, and is not ours to read or
       remove. *)
    let names =
      List.sort compare
        (List.filter (fun n -> n <> "" && n.[0] >= '0' && n.[0] <= '9') names)
    in
    let read id =
      Lwt.catch
        (fun () ->
          let+ body =
            Lwt_io.with_file ~mode:Lwt_io.Input (Filename.concat t.dir id)
              Lwt_io.read
          in
          job_of_json (Yojson.Basic.from_string body))
        (fun _ -> Lwt.return_none)
    in
    let+ () =
      Lwt_list.iter_s
        (fun id ->
          let* job = read id in
          match job with
            | Some job ->
                Queue.push { id; job } t.jobs;
                Lwt.return_unit
            | None ->
                (* Nothing can replay it, and leaving it would stall the lane on
                   every start. *)
                Log.err "lane %s: unreadable job %s, discarding" t.name id;
                Fs_util.unlink_quiet (Filename.concat t.dir id))
        names
    in
    if not (Queue.is_empty t.jobs) then
      Log.info "lane %s: resuming %d queued job(s)" t.name (Queue.length t.jobs)

(* {1 The composite} *)

type t = {
  backend : (module Backend.S);
  lanes : (string * (unit -> lane_stats)) list;
}

(* [inners]: the authoritative backends — the head serves every read, a write
     fans out to all of them, which is exactly what [Backends.Make] states.
   [chunk_keys]: the bare ["<h1>-<h2>"] keys a manifest body names, and [[]] for
     a body that is not a manifest. Injected so this library stays below
     [Chunk_table].
   [log_dir]: where each lane keeps what it still owes, one directory per target.
   [resume]: pick up what a previous run left there. The daemon does; a one-shot
     command does not, so two processes cannot run one lane's jobs at once and
     reorder a rename's copy and delete. *)
let make ?(resume = false) ~chunk_prefix ~(chunk_keys : string -> string list)
    ~log_dir ~(inners : (module Backend.S) list) ~(targets : sub list) () : t =
  let (module Pri : Backend.S) =
    match inners with b :: _ -> b | [] -> failwith "no backends configured"
  in
  let is_chunk key = String.starts_with ~prefix:chunk_prefix key in
  let skipped t key =
    List.exists (fun p -> String.starts_with ~prefix:p key) t.skip_prefixes
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
      | Put key -> (
          let* data = Pri.get_opt ~key () in
          match data with
            (* Gone from the mains since: a later delete, queued behind this,
               says so. *)
            | None -> Lwt.return_unit
            | Some data ->
                let* () = Lwt_list.iter_s (ensure_chunk t) (chunk_keys data) in
                T.put ~key ~data ())
      | Copy (src, dst) ->
          Lwt.catch
            (fun () -> T.copy ~src_key:src ~dst_key:dst ())
            (fun _ ->
              (* The target has no [src]: added after it was written, or its job
                 was dropped. The authoritative [dst] exists by now, so rebuild
                 from that, chunk check included. *)
              run t (Put dst))
      | Delete key ->
          Hashtbl.remove t.ensured key;
          T.delete ~key ()
      | Delete_multi keys ->
          List.iter (fun k -> Hashtbl.remove t.ensured k) keys;
          T.delete_multi keys
  in
  (* One sequential worker per target: order is the point, and a stalled target
     must not stall the others.

     A job stays at the head of the queue until the target takes it, so a failure
     that can clear — the link is down, the store is throttling — is waited out
     rather than losing the write. A permanent one is dropped, since the same
     request will be refused again and every later rename would queue behind it
     forever; the lane is degraded from then on and needs resync-remote. *)
  let rec loop t =
    match Queue.peek_opt t.jobs with
      | None ->
          t.idle <- true;
          Lwt_condition.broadcast t.settled ();
          let* () = Lwt_condition.wait t.wake in
          loop t
      | Some e ->
          t.idle <- false;
          let* outcome =
            Lwt.catch
              (fun () ->
                let+ () = run t e.job in
                `Done)
              (fun exn -> Lwt.return (`Failed exn))
          in
          let* () =
            match outcome with
              | `Done ->
                  t.failures <- 0;
                  ignore (Queue.pop t.jobs);
                  forget t e
              | `Failed exn when Backend.classify exn = Backend.Transient ->
                  t.failures <- t.failures + 1;
                  (* {!Backend.with_retry}'s curve, with a cap measured against
                     an outage rather than a request: a lane has nobody
                     waiting. *)
                  let delay =
                    Float.min 300.
                      (0.5 *. (2. ** float_of_int (min 10 (t.failures - 1))))
                  in
                  Log.warn "lane %s: %s; retrying in %.1fs (%d)" t.name
                    (Backend.reason exn) delay t.failures;
                  (* Before the sleep, so a drain waiting on this lane learns the
                     target is down now rather than a backoff later. *)
                  Lwt_condition.broadcast t.settled ();
                  Lwt_unix.sleep delay
              | `Failed exn ->
                  t.degraded <- true;
                  Log.err "lane %s: %s (dropped; run tsync resync-remote)"
                    t.name (Backend.reason exn);
                  ignore (Queue.pop t.jobs);
                  forget t e
          in
          Lwt_condition.broadcast t.settled ();
          loop t
  in
  let worker t =
    let* () = if resume then load t else Lwt.return_unit in
    loop t
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
                  Log.warn "lane %s chunk %s: %s" t.name key
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
            skip_prefixes = s.skip_prefixes;
            dir = Filename.concat log_dir (escape s.name);
            jobs = Queue.create ();
            wake = Lwt_condition.create ();
            settled = Lwt_condition.create ();
            recording = Lwt_mutex.create ();
            idle = true;
            seq = 0;
            failures = 0;
            chunks_in_flight = 0;
            ensured = Hashtbl.create 1024;
            degraded = false;
          }
        in
        Lwt.async (fun () -> worker t);
        t)
      targets
  in
  if !lanes = [] && targets <> [] then Backend.on_drain drain_all;
  lanes := !lanes @ targets;
  let fill key f =
    Lwt_list.iter_s
      (fun t -> if skipped t key then Lwt.return_unit else f t)
      targets
  in
  let write f = Lwt_list.iter_s f inners in
  let lane_stats =
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
            if is_chunk key then begin
              forward_chunk t key data;
              Lwt.return_unit
            end
            else record t (Put key))

      let delete ~key () =
        let* () = write (fun (module B : Backend.S) -> B.delete ~key ()) in
        fill key (fun t -> record t (Delete key))

      let delete_multi keys =
        let* () = write (fun (module B : Backend.S) -> B.delete_multi keys) in
        Lwt_list.iter_s
          (fun t ->
            match List.filter (fun k -> not (skipped t k)) keys with
              | [] -> Lwt.return_unit
              | keys -> record t (Delete_multi keys))
          targets

      let copy ~src_key ~dst_key () =
        let* () =
          write (fun (module B : Backend.S) -> B.copy ~src_key ~dst_key ())
        in
        fill dst_key (fun t -> record t (Copy (src_key, dst_key)))

      (* Reads never touch a lane target: it is behind by construction. A replica
         is read from, but through {!Fallback_backend}, which knows it comes
         after the mains. *)
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

      (* Smallest wins: a limit ignoring the slowest member is not a limit. Only
         the mains, since a lane target is written off the caller's path. *)
      let max_concurrency ~prefix () =
        let+ answers =
          Lwt_list.map_s
            (fun (module B : Backend.S) -> B.max_concurrency ~prefix ())
            inners
        in
        List.fold_left
          (fun acc n ->
            match (acc, n) with
              | Some a, Some b -> Some (min a b)
              | None, some | some, None -> some)
          None answers
    end)
  in
  { backend; lanes = lane_stats }
