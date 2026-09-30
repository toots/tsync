open Tsync_core

type t = { root : string; collectable : unit -> bool }

let create ~collectable root = { root; collectable }
let collectable t = t.collectable ()
let publish_wait = 30.
let file t key = Local_path.path t.root key

let run_open t d =
  match Fs.lstat_opt (file t (Key.gc_run d)) with
    | Some _ -> true
    | None -> false

let in_surviving t d c =
  match Fs.lstat_opt (file t (Key.chunk d c)) with
    | Some { st_kind = S_REG; _ } -> true
    | _ -> false

let with_publish_lock ?(wait = publish_wait) t d ~exclusive f =
  let p = file t (Key.gc_lock d) in
  Fs.mkdir_p ~perm:0o755 (Filename.dirname p);
  Fs.with_fd
    (Fs.openfile ~perm:0o644 p [O_RDWR; O_CREAT])
    (fun fd ->
      let deadline = Rt.now () +. wait in
      let rec take delay =
        if not (Fs.flock ~exclusive ~block:false fd) then (
          if Rt.now () > deadline then
            Fail.raise_ Fail.Deadline ~op:"publish lock"
              "%s: a collection holds the publish lock"
              (Key.to_string (Key.gc_lock d));
          Rt.sleep delay;
          take (Float.min 0.1 (delay *. 2.)))
      in
      take 0.005;
      Fun.protect ~finally:(fun () -> Fs.funlock fd) f)

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

let is_record body =
  match Yojson.Safe.from_string (Bigstring.to_string body) with
    | `Assoc _ -> true
    | _ -> false
    | exception _ -> false

let names_of key body =
  if Key.is_internal_leaf (Key.leaf key) then []
  else if Manifest.is_manifest body then
    List.sort_uniq Chunk_key.compare (Manifest.chunk_names body)
  else if is_record body then []
  else
    Fail.invalid ~op:"publish" "%s: neither a manifest nor a folder record"
      (Key.to_string key)

let gate t ~key ~body write =
  match Key.domain_of_reference key with
    | Some d when collectable t -> (
        match names_of key (body ()) with
          | [] -> write ()
          | names ->
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

(* A miss in both spaces re-reads the surviving one: a promotion between the
   two reads moved the chunk behind the reader. *)
let read t key f =
  match f key with
    | Some v -> Some v
    | None -> (
        match Key.chunk_parts key with
          | Some (d, c) when collectable t && run_open t d -> (
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
    let listed = raw p in
    let outgoing =
      match Key.outgoing_prefix p with Some fp -> raw fp | None -> []
    in
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
