open Tsync_core

type t = { root : string }

let create root = { root }
let root t = t.root

(* gc.md A1: a network filesystem may be written by another host.

   Asked on every use, since a share may be mounted over the root after start. *)
let collectable t = not (Fs.is_network_fs t.root)
let publish_wait = 30.

let of_store (store : Store.t) =
  match store.local_path with
    | Some root ->
        let t = create root in
        if collectable t then Some t else None
    | None -> None

let file t key = Local_path.path t.root key

let run_open t d =
  match Fs.lstat_opt (file t (Key.gc_run d)) with
    | Some _ -> true
    | None -> false

let in_surviving t d c =
  match Fs.lstat_opt (file t (Key.chunk d c)) with
    | Some { st_kind = S_REG; _ } -> true
    | _ -> false

(* Its own file: closing any descriptor of the run lock's file would drop this
   process's record lock on it. Opened for reading, so closing it is no write
   for the watch on the cursor's directory to wake on. *)
let with_publish_lock ?(wait = publish_wait) t d ~exclusive f =
  let p = file t (Key.gc_publish_lock d) in
  Fs.mkdir_p ~perm:0o755 (Filename.dirname p);
  Fs.with_fd
    (Fs.openfile ~perm:0o644 p [O_RDONLY; O_CREAT])
    (fun fd ->
      let deadline = Rt.now () +. wait in
      let rec take delay =
        if not (Fs.flock ~exclusive ~block:false fd) then (
          if Rt.now () > deadline then
            Fail.raise_ Fail.Deadline ~op:"publish lock" "%s: %s"
              (Key.to_string (Key.gc_publish_lock d))
              (if exclusive then
                 "publications in progress kept the publish lock from a \
                  collection"
               else "a collection holds the publish lock");
          Rt.sleep delay;
          take (Float.min 0.1 (delay *. 2.)))
      in
      take 0.005;
      Fun.protect ~finally:(fun () -> Fs.funlock fd) f)

let sessions_m = Mutex.create ()
let sessions : (string, unit) Hashtbl.t = Hashtbl.create 4

(* Record locks of one process merge, so a second session in this process is
   excluded by a check-and-set with no suspension point, taken first. *)
let with_run_lock t d f =
  let p = file t (Key.gc_lock d) in
  let claimed =
    Mutex.protect sessions_m (fun () ->
        if Hashtbl.mem sessions p then false
        else (
          Hashtbl.replace sessions p ();
          true))
  in
  if not claimed then Error `Busy
  else
    Fun.protect
      ~finally:(fun () ->
        Mutex.protect sessions_m (fun () -> Hashtbl.remove sessions p))
      (fun () ->
        Fs.mkdir_p ~perm:0o755 (Filename.dirname p);
        Fs.with_fd
          (Fs.openfile ~perm:0o644 p [O_RDWR; O_CREAT])
          (fun fd ->
            match Fs.eintr (fun () -> Unix.lockf fd Unix.F_TLOCK 0) with
              | () -> Ok (f ())
              | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
                  Error `Busy
              | exception Unix.Unix_error (e, fn, a) ->
                  raise (Fail.E (Fail.of_unix e fn a))))

let promote t d c =
  let src = file t (Key.chunk_from d c) and dst = file t (Key.chunk d c) in
  let attempt () =
    match Fs.eintr (fun () -> Unix.rename src dst) with
      | () -> true
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
      | exception Unix.Unix_error (e, fn, a) ->
          raise (Fail.E (Fail.of_unix e fn a))
  in
  attempt ()
  ||
  (Fs.mkdir_p ~perm:0o755 (Filename.dirname dst);
   attempt ())

(* A rename is durable once its destination directory is. *)
let sync_shards t d cs =
  List.sort_uniq String.compare
    (List.map (fun c -> Filename.dirname (file t (Key.chunk d c))) cs)
  |> List.iter Fs.fsync_dir

let references key body =
  if Key.is_internal_leaf (Key.leaf key) then Ok []
  else if Manifest.is_manifest body then
    Result.map
      (List.sort_uniq Chunk_key.compare)
      (Result.map_error
         (Printf.sprintf "%s: %s" (Key.to_string key))
         (Manifest.chunk_names body))
  else (
    match Folder.classify_marker (Bigstring.to_string body) with
      | `Marker _ -> Ok []
      | `Unclassifiable | `Not_marker ->
          Error
            (Printf.sprintf "%s: neither a manifest nor a folder marker"
               (Key.to_string key)))

let gate t ~key ~body write =
  match Key.domain_of_reference key with
    | Some d when collectable t -> (
        match references key (body ()) with
          | Error reason -> Fail.raise_ Fail.Invalid ~op:"publish" "%s" reason
          | Ok [] -> write ()
          | Ok names ->
              with_publish_lock t d ~exclusive:false (fun () ->
                  if run_open t d then
                    sync_shards t d (List.filter (promote t d) names);
                  match
                    List.filter (fun c -> not (in_surviving t d c)) names
                  with
                    | [] -> write ()
                    | missing ->
                        raise
                          (Fail.E
                             (Fail.make ~op:"publish"
                                (Missing_chunks
                                   (List.map Chunk_key.to_string missing))
                                (Printf.sprintf "%s names %d missing chunks"
                                   (Key.to_string key) (List.length missing)))))
        )
    | _ -> write ()

(* The outgoing space is read under the shared publish lock, so no reader sees a
   shard its doom step is emptying; a miss there re-reads the surviving space,
   where a promotion may have moved the chunk behind the reader. *)
let read t key f =
  match f key with
    | Some v -> Some v
    | None -> (
        match Key.chunk_parts key with
          | Some (d, c) when collectable t && run_open t d ->
              with_publish_lock t d ~exclusive:false (fun () ->
                  match f (Key.chunk_from d c) with
                    | Some v -> Some v
                    | None -> f key)
          | _ -> None)

let twins t key =
  match Key.chunk_parts key with
    | Some (d, c) when collectable t -> [key; Key.chunk_from d c]
    | _ -> [key]

let list t p raw =
  if not (collectable t) then raw p
  else (
    (* The outgoing space first: a chunk promoted between the two listings is
       then in one of them, where the other order could miss it in both. *)
    let outgoing =
      match Key.outgoing_prefix p with Some fp -> raw fp | None -> []
    in
    let listed = raw p in
    let surviving, rest =
      List.partition
        (fun (e : Store.entry) -> not (Key.is_outgoing e.key))
        listed
    in
    let seen = Hashtbl.create 64 in
    List.iter (fun (e : Store.entry) -> Hashtbl.replace seen e.key ()) surviving;
    let moved =
      List.filter_map
        (fun (e : Store.entry) ->
          match Key.outgoing_chunk e.key with
            | Some (d, c) ->
                let k = Key.chunk d c in
                if Key.under p k && not (Hashtbl.mem seen k) then (
                  Hashtbl.replace seen k ();
                  Some { e with key = k })
                else None
            | None -> None)
        (rest @ outgoing)
    in
    surviving @ moved)
