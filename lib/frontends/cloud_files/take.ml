open Tsync_core
open Tsync_owner
open Tsync_cloud_files_rules

(* cloud-files §16 *)
let take_settle = 2.
let replica_sweep = 3600.

type t = {
  handler : Handler.t;
  root : string;
  staging : string;
  read_only : bool;
  due : (string, float) Hashtbl.t;
  m : Mutex.t;
  untaken : int Atomic.t;
  takes : int Atomic.t;
}

let create ~engine:_ ~handler ~root ~staging ~read_only () =
  {
    handler;
    root;
    staging;
    read_only;
    due = Hashtbl.create 64;
    m = Mutex.create ();
    untaken = Atomic.make 0;
    takes = Atomic.make 0;
  }

let untaken t = Atomic.get t.untaken
let takes t = Atomic.get t.takes

let schedule_at t path at =
  Mutex.protect t.m (fun () -> Hashtbl.replace t.due path at)

let schedule t path = schedule_at t path (Unix.gettimeofday () +. take_settle)
let call t request = Rt.run_sync (fun () -> Handler.call t.handler request)

let identity_of (row : Protocol.row) =
  Identity.encode
    (Identity.of_item ~ref_:row.ref_ ~is_dir:(row.kind = `Dir)
       ~content_id:row.content_id)

(* The item the bytes or the folder now are: the conflicted copy when the
   domain held the place (§9.3). *)
let landed (item : Protocol.row) (aside : Protocol.row option) =
  Option.value ~default:item aside

let untake t path why =
  Atomic.incr t.untaken;
  Log.info "cloud_files: %s is not taken: %s" path why

let copy_to_staging t path =
  Fs.mkdir_p t.staging;
  let dst = Fs.temp_in t.staging in
  In_channel.with_open_bin path (fun ic ->
      Out_channel.with_open_bin dst (fun oc ->
          let buffer = Bytes.create 65536 in
          let rec pump () =
            match In_channel.input ic buffer 0 (Bytes.length buffer) with
              | 0 -> ()
              | n ->
                  Out_channel.output oc buffer 0 n;
                  pump ()
          in
          pump ()));
  dst

(* The item's place once the domain answered: renamed to the conflicted copy's
   name when it landed aside. *)
let follow_aside path (item : Protocol.row) =
  let dst = Filename.concat (Filename.dirname path) item.name in
  if not (Win_path.same path dst) then Sys.rename path dst

let rec take t path =
  if Names.is_temp_name (Filename.basename path) then `Done
  else (
    match Cf.state path with
      | None -> `Done
      | Some st when st.other_reparse ->
          untake t path "a link or another provider's item";
          `Done
      | Some st when st.placeholder && Identity.decode st.identity = None ->
          untake t path "a placeholder of another provider";
          `Done
      | Some st when st.placeholder && st.in_sync -> `Done
      | Some _ when t.read_only ->
          untake t path "the domain is read-only";
          `Done
      | Some st -> (
          match parent_ref t path with
            | None -> `Done
            | Some parent_ref ->
                if st.is_dir then take_folder t path st parent_ref
                else take_file t path st parent_ref))

(* §9.3: a parent the domain does not hold yet is taken first, which takes its
   children, this one among them. *)
and parent_ref t path =
  let parent = Filename.dirname path in
  if Win_path.same parent t.root then Some "root"
  else (
    match Cf.state parent with
      | Some ps when ps.placeholder ->
          Option.map
            (fun (i : Identity.t) -> i.ref_)
            (Identity.decode ps.identity)
      | Some _ ->
          ignore (take t parent);
          None
      | None -> None)

and take_folder t path (st : Cf.state) parent_ref =
  let item, aside =
    match Identity.decode st.identity with
      | Some id when st.placeholder -> (
          match call t (Stat (Ref id.ref_)) with row -> (row, None))
      | _ ->
          let (p : Protocol.placed) =
            call t
              (Mkdir
                 {
                   at = { parent_ref; name = Filename.basename path };
                   exclusive = false;
                   aside = true;
                 })
          in
          (p.item, p.aside)
  in
  let got = landed item aside in
  match Cf.hold path with
    | None -> `Again
    | Some h ->
        Fun.protect
          ~finally:(fun () -> Cf.release h)
          (fun () ->
            Cf.set_identity h ~placeholder:st.placeholder (identity_of got)
              ~in_sync:true);
        Atomic.incr t.takes;
        Log.info "cloud_files: took the folder %s" path;
        let path =
          match aside with
            | Some a ->
                follow_aside path a;
                Filename.concat (Filename.dirname path) a.name
            | None -> path
        in
        Array.iter
          (fun name -> ignore (take t (Filename.concat path name)))
          (try Sys.readdir path with Sys_error _ -> [||]);
        `Done

(* §9.3: settled is unchanged for TAKE_SETTLE and openable by no other writer;
   the bytes copied are marked in sync only if nothing changed them since. *)
and take_file t path (st : Cf.state) parent_ref =
  match Cf.hold path with
    | None -> `Again
    | Some h when Cf.held_usn h <> st.usn ->
        Cf.release h;
        `Again
    | Some h -> (
        Cf.release h;
        let staging = copy_to_staging t path in
        let (w : Protocol.written) =
          match Identity.decode st.identity with
            | Some id when st.placeholder ->
                call t
                  (Write
                     {
                       at = Ref id.ref_;
                       staging;
                       base = Some id.content_id;
                       exclusive = false;
                       aside = false;
                       await = false;
                     })
            | _ ->
                call t
                  (Write
                     {
                       at = Child { parent_ref; name = Filename.basename path };
                       staging;
                       base = None;
                       exclusive = false;
                       aside = true;
                       await = false;
                     })
        in
        let got = landed w.item w.aside in
        match Cf.hold path with
          | None ->
              (* A writer came back: the identity waits for the next take. *)
              `Again
          | Some h ->
              Fun.protect
                ~finally:(fun () -> Cf.release h)
                (fun () ->
                  Cf.set_identity h ~placeholder:st.placeholder
                    (identity_of got)
                    ~in_sync:(Cf.held_usn h = st.usn));
              Atomic.incr t.takes;
              Log.info "cloud_files: took %s" path;
              Option.iter (follow_aside path) w.aside;
              `Done)

let take_logged t path =
  match take t path with
    | `Done -> ()
    | `Again ->
        Log.debug "cloud_files: %s is not settled; taken later" path;
        schedule t path
    | exception e ->
        Log.warn "cloud_files: taking %s: %s" path (Printexc.to_string e);
        schedule_at t path (Unix.gettimeofday () +. 30.)

(* §9.4: every item of the populated folders that is owed, which the in-sync
   bit records on the volume; a folder never listed holds nothing to take. *)
let sweep t =
  let rec walk dir =
    Array.iter
      (fun name ->
        let path = Filename.concat dir name in
        match Cf.state path with
          | Some st when st.is_dir && st.placeholder ->
              if not st.in_sync then schedule_at t path 0.;
              if not st.unpopulated then walk path
          | Some st when st.placeholder && st.in_sync -> ()
          | Some _ -> schedule_at t path 0.
          | None -> ())
      (try Sys.readdir dir with Sys_error _ -> [||])
  in
  walk t.root

let sweep_key = "\000sweep"

(* ponytail: polls the queue every quarter second, which TAKE_SETTLE dwarfs; a
   timed wait would need a condition the stdlib lacks. *)
let rec next t =
  let now = Unix.gettimeofday () in
  let ready =
    Mutex.protect t.m (fun () ->
        let soonest =
          Hashtbl.fold
            (fun path at acc ->
              match acc with
                | Some (_, a) when a <= at -> acc
                | _ -> Some (path, at))
            t.due None
        in
        match soonest with
          | Some (path, at) when at <= now ->
              Hashtbl.remove t.due path;
              Some path
          | _ -> None)
  in
  match ready with
    | Some path -> path
    | None ->
        Thread.delay 0.25;
        next t

let rec work t =
  (match next t with
    | path when path = sweep_key -> (
        try sweep t
        with e -> Log.warn "cloud_files: sweep: %s" (Printexc.to_string e))
    | path -> take_logged t path);
  work t

let rec watch t w =
  (match Cf.watch_read w with
    | Some events ->
        List.iter
          (fun (_action, rel) -> schedule t (Filename.concat t.root rel))
          events
    | None ->
        Log.info "cloud_files: the watch lost events; sweeping";
        schedule_at t sweep_key 0.);
  watch t w

let rec periodic t =
  Thread.delay replica_sweep;
  schedule_at t sweep_key 0.;
  periodic t

let start t =
  let w = Cf.watch_open t.root in
  ignore (Thread.create (fun () -> watch t w) ());
  ignore (Thread.create (fun () -> work t) ());
  ignore (Thread.create (fun () -> periodic t) ());
  schedule_at t sweep_key 0.
