type op =
  | Put of { key : Stored_key.t; data : Bigstring.t }
  | Copy of { src_key : Stored_key.t; dst_key : Stored_key.t }
  | Delete of Stored_key.t
  | Delete_multi of Stored_key.t list

type stats = { queued : int; in_flight : int; degraded : bool }

(* What a target still owes. Bodyless on purpose: see the .mli. *)
type job =
  | Job_put of Stored_key.t
  | Job_copy of Stored_key.t * Stored_key.t
  | Job_delete of Stored_key.t
  | Job_delete_multi of Stored_key.t list

module Over
    (Io : Io.S)
    (Queues : Durable_queue.S with type 'a io := 'a Io.t)
    (Lock : Lock.S with type 'a io := 'a Io.t) =
struct
  module type Store = Backend.S with type 'a io := 'a Io.t

  open Io_syntax.Make (Io)

  module Q = Queues.Make (struct
    type t = job

    let to_string job =
      Yojson.Basic.to_string
        (match job with
          | Job_put key ->
              `Assoc
                [
                  ("op", `String "put");
                  ("key", `String (Stored_key.to_string key));
                ]
          | Job_copy (src, dst) ->
              `Assoc
                [
                  ("op", `String "copy");
                  ("src", `String (Stored_key.to_string src));
                  ("dst", `String (Stored_key.to_string dst));
                ]
          | Job_delete key ->
              `Assoc
                [
                  ("op", `String "delete");
                  ("key", `String (Stored_key.to_string key));
                ]
          | Job_delete_multi keys ->
              `Assoc
                [
                  ("op", `String "delete_multi");
                  ( "keys",
                    `List
                      (List.map
                         (fun k -> `String (Stored_key.to_string k))
                         keys) );
                ])

    let of_string body =
      let open Yojson.Basic.Util in
      match Yojson.Basic.from_string body with
        | exception _ -> None
        | json -> (
            match json |> member "op" |> to_string with
              | "put" ->
                  Some
                    (Job_put
                       (Stored_key.listed (json |> member "key" |> to_string)))
              | "copy" ->
                  Some
                    (Job_copy
                       ( Stored_key.listed (json |> member "src" |> to_string),
                         Stored_key.listed (json |> member "dst" |> to_string)
                       ))
              | "delete" ->
                  Some
                    (Job_delete
                       (Stored_key.listed (json |> member "key" |> to_string)))
              | "delete_multi" ->
                  Some
                    (Job_delete_multi
                       (json |> member "keys" |> to_list
                       |> List.map (fun k -> Stored_key.listed (to_string k))))
              | _ -> None
              | exception _ -> None)
  end)

  module type S = sig
    val name : string
    val backend : (module Store)
    val accept : op -> unit Io.t
    val skip : Stored_key.t -> bool
    val readable : (module Store) option
    val stats : unit -> stats
  end

  (* Past this, a chunk PUT is dropped rather than held in memory: the manifest job
     fetches it later. *)
  let max_chunks_in_flight = 32

  (* ponytail: crude memo — reset the whole table past the cap rather than keeping
     an LRU, overflowing costing only a HEAD per chunk again. Per-key eviction if
     the extra HEADs ever show up in a profile. *)
  let max_ensured = 100_000

  (* A target's directory is named after the store, which is whatever the config
     says, so anything outside the safe set becomes [%XX] and a name with a slash
     in it cannot climb out of the root. *)
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

  let log_dir ~root ~name = Filename.concat root (escape name)
  let release ~root ~name = Durable_queue.release (log_dir ~root ~name)

  let make ?(resume = false) ?chunk_from_prefix ~name ~backend ~source
      ~chunk_prefix ~(chunk_keys : string -> string list) ~journal_prefix
      ~cursor_key ~(excluded : Stored_key.t -> bool) ~reads_reach ~root () :
      (module S) =
    let (module Target : Store) = backend in
    let (module Source : Store) = source in
    let module L = Chunk_layout.Make (struct
      let chunk_prefix = chunk_prefix
    end) in
    (* Chunk keys the target is known to hold, so a copy of an already-filled
       file costs nothing per chunk. *)
    let ensured : (Stored_key.t, unit) Hashtbl.t = Hashtbl.create 1024 in

    (* Shards whose listing has been folded into [ensured]. A manifest's chunks
       hash across as many shards as it has members, so this pays off across jobs
       rather than within one: a run works through manifests in the tens of
       thousands and keeps meeting shards it has already listed. *)
    let known_shards : (string, unit) Hashtbl.t = Hashtbl.create 256 in

    (* Past the cap both go: a key forgotten while its shard stayed known would
       never be learned again, the listing being what fills [ensured]. *)
    let forget_if_full () =
      if Hashtbl.length ensured >= max_ensured then begin
        Hashtbl.reset ensured;
        Hashtbl.reset known_shards
      end
    in
    let remember key =
      forget_if_full ();
      Hashtbl.replace ensured key ()
    in
    let chunks_in_flight = ref 0 in
    let quiet = Lock.condition () in
    (* The source may be mid-collection, in which case a chunk not yet promoted is
       only under the from-space prefix.

       The key written to the target is the plain one either way: a target has one
       space, and never learns the source had two. *)
    let source_body key chunk_key =
      let* data = Source.get_opt ~key () in
      match (data, chunk_from_prefix) with
        | Some data, _ -> Io.return data
        | None, None -> Source.get ~key ()
        | None, Some prefix ->
            Source.get
              ~key:
                (Stored_key.in_space ~prefix
                   (Chunk_layout.relative_path chunk_key))
              ()
    in
    (* A shard listing reaches the same keys a HEAD under that prefix does: a
       chunk still in the from-space of an open collection is under neither. *)
    let learn_shard shard =
      if Hashtbl.mem known_shards shard then Io.return ()
      else
        let+ entries = Target.list_prefix ~prefix:(L.shard_prefix shard) () in
        forget_if_full ();
        List.iter
          (fun (e : Backend.file_entry) ->
            Hashtbl.replace ensured e.Backend.key ())
          entries;
        Hashtbl.replace known_shards shard ()
    in
    let ensure_chunk chunk_key =
      let key = L.key chunk_key in
      if Hashtbl.mem ensured key then Io.return ()
      else
        let* () = learn_shard (Chunk_layout.shard_of chunk_key) in
        if Hashtbl.mem ensured key then Io.return ()
        else
          let* data = source_body key chunk_key in
          let+ () = Target.put ~key ~data () in
          remember key
    in
    let rec run job =
      match job with
        | Job_put key -> (
            let* data = Source.get_opt ~key () in
            match data with
              (* Gone from the source since: a later delete, queued behind this,
                 says so. *)
              | None -> Io.return ()
              | Some data ->
                  let* () =
                    iter_s ensure_chunk (chunk_keys (Bigstring.to_string data))
                  in
                  Target.put ~key ~data ())
        | Job_copy (src, dst) ->
            Io.catch
              (fun () -> Target.copy ~src_key:src ~dst_key:dst ())
              (fun _ ->
                (* The target has no [src]: added after it was written, or its job
                   was dropped. The authoritative [dst] exists by now, so rebuild
                   from that, chunk check included. *)
                run (Job_put dst))
        | Job_delete key ->
            Hashtbl.remove ensured key;
            Target.delete ~key ()
        | Job_delete_multi keys ->
            List.iter (fun k -> Hashtbl.remove ensured k) keys;
            Target.delete_multi keys
    in
    let queue =
      Q.ordered ~name:("deferred " ^ name)
        ~log:(Q.Records.create ~dir:(log_dir ~root ~name))
          (* A permanent failure is dropped: the same request would be refused
             again, and every later rename would queue behind it forever. The
             target is degraded from then on and needs tsync mirror. *)
        ~classify:Backend.classify ~poison:Durable_queue.Drop ~run ()
    in
    Q.start ~recover:resume queue;
    (* Chunk pushes are not owed — a manifest job fetches whatever is missing — but
       one still in flight when a command exits would land after everything else
       has gone quiet. *)
    let rec chunks_quiet () =
      if !chunks_in_flight = 0 then Io.return ()
      else
        let* () = Lock.wait quiet in
        chunks_quiet ()
    in
    Queues.register_settle chunks_quiet;
    (* Best-effort and unrecorded: correctness rests entirely on the manifest job's
       chunk check, so dropping one only costs that job a fetch.

       Dedup means a file copy or an incremental re-upload issues no chunk PUTs at
       all, which is why the durable log holds one record per user-visible
       operation rather than one per chunk. *)
    let forward_chunk key data =
      if Hashtbl.mem ensured key || !chunks_in_flight >= max_chunks_in_flight
      then ()
      else begin
        incr chunks_in_flight;
        Io.async (fun () ->
            Io.finalize
              (fun () ->
                Io.catch
                  (fun () ->
                    let+ () = Target.put ~key ~data () in
                    remember key)
                  (fun exn ->
                    Log.warn "deferred %s chunk %s: %s" name
                      (Stored_key.to_string key) (Printexc.to_string exn);
                    Io.return ()))
              (fun () ->
                decr chunks_in_flight;
                Lock.broadcast quiet;
                Io.return ()))
      end
    in
    (module struct
      let name = name
      let backend = backend
      let readable = if reads_reach then Some backend else None

      (* Nothing reads the journal or cursor from a target reads never reach, so
         carrying them would be dead weight; a replica carries them because a peer
         reading it needs them. *)
      let skip key =
        excluded key
        || (not reads_reach)
           && (Stored_key.is_in ~prefix:journal_prefix key || key = cursor_key)

      let stats () =
        let s = Q.stats queue in
        {
          queued = s.Durable_queue.queued;
          in_flight = !chunks_in_flight;
          degraded = s.Durable_queue.degraded;
        }

      let accept = function
        | Put { key; data } when Stored_key.is_in ~prefix:chunk_prefix key ->
            forward_chunk key data;
            Io.return ()
        | Put { key; _ } -> Q.post queue (Job_put key)
        | Copy { src_key; dst_key } ->
            Q.post queue (Job_copy (src_key, dst_key))
        | Delete key -> Q.post queue (Job_delete key)
        | Delete_multi keys -> Q.post queue (Job_delete_multi keys)
    end)
end
