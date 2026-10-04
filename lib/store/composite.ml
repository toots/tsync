open Tsync_core

type role = Main | Replica | Backfill | Read_only

let role_of_string = function
  | "main" -> Some Main
  | "replica" -> Some Replica
  | "backfill" -> Some Backfill
  | "readOnly" -> Some Read_only
  | _ -> None

let role_to_string = function
  | Main -> "main"
  | Replica -> "replica"
  | Backfill -> "backfill"
  | Read_only -> "readOnly"

let read_rank = function
  | Main -> 0
  | Replica -> 1
  | Read_only -> 2
  | Backfill -> 3

type job =
  | Put of Key.t
  | Copy of Key.t * Key.t
  | Delete of Key.t
  | Delete_many of Key.t list
  | Collection_delete of {
      keys : Key.t list;
      run : string;
      shard : string;
      generation : int;
    }

type record = {
  job : job;
  attempts : int;
  last_error : (string * string) option;
}

let key_json k = `String (Key.to_string k)

let encode_record r =
  let base =
    match r.job with
      | Put k -> [("op", `String "put"); ("key", key_json k)]
      | Copy (s, d) ->
          [("op", `String "copy"); ("src", key_json s); ("dst", key_json d)]
      | Delete k -> [("op", `String "delete"); ("key", key_json k)]
      | Delete_many ks ->
          [
            ("op", `String "delete_multi");
            ("keys", `List (List.map key_json ks));
          ]
      | Collection_delete c ->
          [
            ("op", `String "delete_multi");
            ("keys", `List (List.map key_json c.keys));
            ("run", `String c.run);
            ("shard", `String c.shard);
            ("generation", `Int c.generation);
          ]
  in
  let note =
    (if r.attempts > 0 then [("attempts", `Int r.attempts)] else [])
    @
      match r.last_error with
      | Some (k, d) ->
          [("lastError", `Assoc [("kind", `String k); ("detail", `String d)])]
      | None -> []
  in
  Yojson.Safe.to_string (`Assoc (base @ note))

let decode_record body =
  match Yojson.Safe.from_string body with
    | exception _ -> None
    | `Assoc f ->
        let str n =
          match List.assoc_opt n f with Some (`String s) -> Some s | _ -> None
        in
        let key n = Option.bind (str n) Key.of_string in
        let keys () =
          match List.assoc_opt "keys" f with
            | Some (`List l) ->
                let ks =
                  List.filter_map
                    (function `String s -> Key.of_string s | _ -> None)
                    l
                in
                if List.length ks = List.length l then Some ks else None
            | _ -> None
        in
        let attempts =
          match List.assoc_opt "attempts" f with Some (`Int n) -> n | _ -> 0
        in
        let last_error =
          match List.assoc_opt "lastError" f with
            | Some (`Assoc e) -> (
                match (List.assoc_opt "kind" e, List.assoc_opt "detail" e) with
                  | Some (`String k), Some (`String d) -> Some (k, d)
                  | _ -> None)
            | _ -> None
        in
        let job =
          match str "op" with
            | Some "put" -> Option.map (fun k -> Put k) (key "key")
            | Some "copy" -> (
                match (key "src", key "dst") with
                  | Some s, Some d -> Some (Copy (s, d))
                  | _ -> None)
            | Some "delete" -> Option.map (fun k -> Delete k) (key "key")
            | Some "delete_multi" -> (
                match
                  ( keys (),
                    str "run",
                    str "shard",
                    List.assoc_opt "generation" f )
                with
                  | Some ks, None, None, None -> Some (Delete_many ks)
                  | Some ks, Some run, Some shard, Some (`Int generation) ->
                      Some
                        (Collection_delete { keys = ks; run; shard; generation })
                  | _ -> None)
            | _ -> None
        in
        Option.map (fun job -> { job; attempts; last_error }) job
    | _ -> None

let escape_name n =
  String.concat ""
    (List.map
       (fun c ->
         if
           (c >= 'a' && c <= 'z')
           || (c >= 'A' && c <= 'Z')
           || (c >= '0' && c <= '9')
           || c = '.' || c = '_' || c = '-'
         then String.make 1 c
         else Printf.sprintf "%%%02X" (Char.code c))
       (List.of_seq (String.to_seq n)))

type member = { name : string; role : role; store : Store.t }
type knowledge = { is_index : Key.t -> bool; is_journal : Key.t -> bool }

(* The job a copy log is running, for the status report. *)
type running = {
  key : string;
  mutable file : (string * int) option;
  started : float;
  mutable chunks : int;
  mutable checked : int;
  mutable sent : int;
}

type copy = {
  member : member;
  reads_reach : bool;
  records : Dqueue.Records.t;
  queue : record Dqueue.t;
  memo_m : Mutex.t;
  memo : Copy_memo.t;
  forwards : Rt.Semaphore.t;
  discards : Discards.t;
  mutable running : running option;  (** under [memo_m] *)
}

type core = {
  domain : Domain_name.t;
  mains : member list;
  archives : member list;
  copies : copy list;
  functions : (string * Bucket_function.t) list;
      (** by member name: each main and copy whose store may run one *)
  readable : member list;
  owner : bool;
  poke : unit -> unit;
  knowledge : knowledge;
  heard : (string, unit) Hashtbl.t;
  heard_m : Mutex.t;
  settle_pending : bool Atomic.t;
  timing : timing;
}

and timing = { discard_poll : float; probe_poll : float; probe_wait : float }

type t = { core : core; source_store : Store.t; whole : Store.t }

let skip k c key =
  k.knowledge.is_index key
  || (c.member.role = Backfill && k.knowledge.is_journal key)

let unreachable m = Fail.raise_ Fail.Unreachable "%s is held down" m.name

(* replication §4.6: the last candidate is asked whatever its health; a held
   member is passed over at once. *)
let ask ~probing ~last m f =
  if last then f m.store
  else if probing then (
    match Health.check m.store.health with
      | `Held -> unreachable m
      | `Up | `Probe -> Retry.until_held m.store.health (fun () -> f m.store))
  else if Health.is_down m.store.health then unreachable m
  else Retry.until_held m.store.health (fun () -> f m.store)

type 'a walk = Answer of 'a | Miss | Unreach of exn

let walk ~probing ~stop_on_miss chain f =
  let n = List.length chain in
  let rec go i first_err = function
    | [] -> ( match first_err with Some e -> Unreach e | None -> Miss)
    | m :: rest -> (
        match ask ~probing ~last:(i = n - 1) m f with
          | Some v -> Answer v
          | None ->
              (* A copy's miss stands for the domain only when no main before
                 it failed (failure-model §5.2). *)
              if stop_on_miss && (first_err = None || m.role = Main) then Miss
              else go (i + 1) first_err rest
          | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
          | exception e ->
              go (i + 1) (match first_err with None -> Some e | s -> s) rest)
  in
  go 0 None chain

(* failure-model §4.4: when no candidate could answer, the composite answers
   UNREACHABLE with the first candidate's reason. *)
let unreachable_of = function
  | Fail.E ({ kind = Link | Load | Local | Unreachable | Deadline; _ } as f) ->
      Fail.E { f with kind = Unreachable }
  | e -> e

let read ?(probing = true) t f =
  let a = walk ~probing ~stop_on_miss:true t.readable f in
  match a with
    | Answer v -> Some v
    | _ -> (
        let b = walk ~probing ~stop_on_miss:false t.archives f in
        match (b, a) with
          | Answer v, _ -> Some v
          | _, Unreach e -> raise (unreachable_of e)
          | Unreach e, _ -> raise (unreachable_of e)
          | _ -> None)

let settle_retry = 2.
let max_forwards = 4

let submit t c job =
  let r = { job; attempts = 0; last_error = None } in
  if t.owner then ignore (Dqueue.post c.queue r)
  else (
    ignore (Dqueue.Records.create c.records (encode_record r));
    t.poke ())

let fill t job =
  List.iter
    (fun c ->
      let keep k = not (skip t c k) in
      let job =
        match job with
          | Put k -> if keep k then Some (Put k) else None
          | Copy (s, d) -> if keep d then Some (Copy (s, d)) else None
          | Delete k -> if keep k then Some (Delete k) else None
          | Delete_many ks -> (
              match List.filter keep ks with
                | [] -> None
                | ks -> Some (Delete_many ks))
          | Collection_delete _ as j -> Some j
      in
      match job with
        | None -> ()
        | Some (Put k) when Key.chunk_of k <> None && t.owner -> ()
        | Some job -> submit t c job)
    t.copies

(* A best-effort forward of a chunk to a copy: never blocks the writer, and a
   forward that does not happen is fetched by the manifest's job. *)
let forward_chunk c key body =
  match Key.chunk_of key with
    | None -> ()
    | Some ck ->
        let v = Copy_memo.look c.memo in
        if (not (Copy_memo.holds v ck)) && Rt.Semaphore.try_acquire c.forwards
        then
          Rt.spawn ~name:"forward" (fun () ->
              Fun.protect
                ~finally:(fun () -> Rt.Semaphore.release c.forwards)
                (fun () ->
                  match c.member.store.put ~mode:Store.Best_effort key body with
                    | () -> Copy_memo.note v ck
                    | exception Rt.Cancelled -> ()
                    | exception e ->
                        Log.debug "forward %s to %s: %s" (Key.to_string key)
                          c.member.name (Printexc.to_string e)))

let first_main t =
  match t.mains with
    | m :: _ -> m
    | [] -> Fail.raise_ Fail.Read_only "this domain has no writable store"

let put t ?mode key body =
  let m0 = first_main t in
  m0.store.put ?mode key body;
  if t.owner && Key.chunk_of key <> None then
    List.iter
      (fun c -> if not (skip t c key) then forward_chunk c key body)
      t.copies;
  fill t (Put key);
  List.iter (fun m -> m.store.put ?mode key body) (List.tl t.mains)

let put_if_absent t key body =
  let m0 = first_main t in
  let r = m0.store.put_if_absent key body in
  let held = match r with Store.Won -> body | Held b -> b in
  fill t (Put key);
  List.iter (fun m -> m.store.put key held) (List.tl t.mains);
  r

(* replication §4.2: the first main alone evaluates the precondition; an etag
   read from another member never matches it, which answers [Changed]. *)
let put_if_unchanged t ~fill_copies key body expected =
  let m0 = first_main t in
  match m0.store.put_if_unchanged key body expected with
    | Store.Changed -> Store.Changed
    | Written ->
        if fill_copies then fill t (Put key);
        List.iter (fun m -> m.store.put key body) (List.tl t.mains);
        Written

(* replication §4.6: a checksum describes the view the listings describe, so
   only the readable members are asked, never the archives. *)
let compute_checksum t key algo =
  match
    walk ~probing:true ~stop_on_miss:true t.readable (fun s ->
        s.compute_checksum key algo)
  with
    | Answer c -> Some c
    | Miss -> None
    | Unreach e -> raise (unreachable_of e)

let write_all t job f =
  let m0 = first_main t in
  let v = f m0.store in
  fill t job;
  List.iter (fun m -> ignore (f m.store)) (List.tl t.mains);
  v

let probe_main t m =
  match
    Rt.with_timeout ~detach:true Health.probe_timeout (fun () ->
        Retry.ladder ~health:m.store.health ~op:"probe" (fun () ->
            m.store.get_opt (Key.cursor t.domain)))
  with
    | _ ->
        Health.answered m.store.health;
        Mutex.protect t.heard_m (fun () -> Hashtbl.replace t.heard m.name ())
    | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
    | exception e ->
        Health.probe_lost ~reason:(Printexc.to_string e) m.store.health

(* replication §4.9: a copy is never written while a main is offline. *)
let guard t role what =
  if role <> Main then (
    List.iter
      (fun m ->
        let heard =
          Mutex.protect t.heard_m (fun () -> Hashtbl.mem t.heard m.name)
        in
        if
          (not heard)
          || Health.is_down m.store.health
             && not (Health.is_held m.store.health)
        then probe_main t m)
      t.mains;
    match List.find_opt (fun m -> Health.is_down m.store.health) t.mains with
      | Some m ->
          Fail.raise_ Fail.Link "refusing to %s: the main %s is not online" what
            m.name
      | None -> ())

let progress c f = Mutex.protect c.memo_m (fun () -> Option.iter f c.running)

(* A-7.14: a main's rotten chunk parks its copy instead of spreading. *)
let sound_chunk ck b =
  if not (Chunk_key.names ck b) then
    Fail.corrupt "chunk %s does not hash to its key on the main"
      (Chunk_key.to_string ck)

let rec sync t src c key restarts =
  match (src.Store.get_opt key, Key.chunk_of key) with
    | None, ck ->
        Option.iter (fun ck -> Copy_memo.forget c.memo [ck]) ck;
        ignore (c.member.store.delete key)
    | Some b, Some ck ->
        (* A chunk names nothing, whatever its bytes decode as. *)
        sound_chunk ck b;
        c.member.store.put key b;
        Fs.drop_mapped_pages b
    | Some b, None -> (
        let v = Copy_memo.look c.memo in
        let m = Manifest.of_body b in
        let names = Option.fold ~none:[] ~some:Manifest.keys m in
        progress c (fun r ->
            r.chunks <- List.length names;
            r.checked <- 0;
            Option.iter
              (fun (m : Manifest.t) -> r.file <- Some (m.name, m.size))
              m);
        let missing =
          List.find_opt
            (fun ck ->
              let held = ensure_chunk t src c v ck in
              progress c (fun r -> r.checked <- r.checked + 1);
              not held)
            names
        in
        match missing with
          | None ->
              c.member.store.put key b;
              Fs.drop_mapped_pages b
          | Some ck ->
              if
                restarts < 3
                && not
                     (Option.fold ~none:false ~some:(Bigstring.equal b)
                        (src.get_opt key))
              then sync t src c key (restarts + 1)
              else
                Fail.corrupt "source names a chunk no main holds: %s names %s"
                  (Key.to_string key) (Chunk_key.to_string ck))

and ensure_chunk t (src : Store.t) c v ck =
  let d = t.domain in
  let known () =
    if Copy_memo.trusted v then (
      let sss = Chunk_key.shard ck in
      Copy_memo.learn_shard v sss (fun () ->
          List.filter_map
            (fun (e : Store.entry) -> Key.chunk_of e.key)
            (c.member.store.list_prefix (Key.shard_prefix d sss)));
      Copy_memo.holds v ck)
    else c.member.store.head_opt (Key.chunk d ck) <> None
  in
  Copy_memo.holds v ck || known ()
  ||
    match src.get_opt (Key.chunk d ck) with
    | None -> false
    | Some b ->
        sound_chunk ck b;
        c.member.store.put (Key.chunk d ck) b;
        Fs.drop_mapped_pages b;
        progress c (fun r -> r.sent <- r.sent + Bigstring.length b);
        Copy_memo.note v ck;
        true

let main_holds (src : Store.t) key = src.head_opt key <> None

let job_key = function
  | Put k | Delete k | Copy (_, k) -> Key.to_string k
  | Delete_many ks -> Printf.sprintf "%d deletions" (List.length ks)
  | Collection_delete cd -> Printf.sprintf "collection %s" cd.shard

(* A forward in flight when the deletion lands would put a doomed chunk back
   on the copy; later forwards are skipped while every slot is held. *)
let without_forwards c f =
  (* Pitfall C-7.10: a cancel while taking the slots gives back those taken. *)
  let taken = ref 0 in
  Fun.protect
    ~finally:(fun () ->
      for _ = 1 to !taken do
        Rt.Semaphore.release c.forwards
      done)
    (fun () ->
      for _ = 1 to max_forwards do
        Rt.Semaphore.acquire c.forwards;
        incr taken
      done;
      f ())

(* gc §5.7: a copy whose function this owner confirmed is told by requests;
   the restore check waits until the function consumed each one. *)
let function_of t m =
  if m.store.bucket_functions then List.assoc_opt m.name t.functions else None

let confirmed t m =
  match function_of t m with
    | Some f -> Bucket_function.confirmed f
    | None -> false

let queued t c = confirmed t c.member

let run_job_body t src c r =
  guard t c.member.role ("copy to " ^ c.member.name);
  match r.job with
    | Put k | Delete k -> sync t src c k 0
    | Copy (_, d) -> sync t src c d 0
    | Delete_many ks ->
        (* What the main no longer holds goes in one bulk delete; a key it
           holds again is copied instead. *)
        let gone, back = List.partition (fun k -> not (main_holds src k)) ks in
        Copy_memo.forget c.memo (List.filter_map Key.chunk_of gone);
        if gone <> [] then c.member.store.delete_multi gone;
        List.iter (fun k -> sync t src c k 0) back
    | Collection_delete cd ->
        let ks = List.filter (fun k -> not (main_holds src k)) cd.keys in
        Copy_memo.forget c.memo (List.filter_map Key.chunk_of ks);
        if queued t c then (
          if ks <> [] then
            Discards.add c.discards
              {
                run = cd.run;
                shard = cd.shard;
                generation = cd.generation;
                keys = List.map Key.to_string ks;
              }
              ~write:(fun p ->
                without_forwards c (fun () ->
                    c.member.store.put
                      (Discards.request_key t.domain p)
                      (Discards.body p.keys))))
        else (
          let markers = List.filter_map Key.marker_of ks in
          without_forwards c (fun () ->
              c.member.store.delete_multi (ks @ markers));
          List.iter (fun k -> if main_holds src k then sync t src c k 0) cd.keys)

let collection_owed t ~generation () =
  List.fold_left
    (fun n c ->
      List.fold_left
        (fun n id ->
          match Dqueue.Records.read c.records id with
            | `Body b -> (
                match decode_record b with
                  | Some { job = Collection_delete cd; _ }
                    when cd.generation = generation ->
                      n + 1
                  | _ -> n)
            | `Gone -> n)
        n
        (Dqueue.Records.list c.records)
      + List.length
          (List.filter
             (fun (_, (p : Discards.pending)) -> p.generation = generation)
             (Discards.pending c.discards)))
    0 t.copies

(* Whether some main's run lock was busy, so G may still await settling. *)
let settle_generation t =
  List.exists
    (fun m ->
      match Chunk_spaces.of_store m.store with
        | None -> false
        | Some spaces -> (
            match
              Chunk_spaces.with_run_lock spaces t.domain (fun () ->
                  (* A run suspended in closing still dooms under G. *)
                  if not (Chunk_spaces.run_open spaces t.domain) then
                    Gc_generation.settle m.store t.domain ~owed:(fun g ->
                        collection_owed t ~generation:g ()))
            with
              | Ok () -> false
              | Error `Busy -> true))
    t.mains

(* After the job's record completes, and again while a collector holds the run
   lock; one pending attempt per domain. *)
let settle_later t =
  if Atomic.compare_and_set t.settle_pending false true then
    Rt.spawn ~name:"settle generation" (fun () ->
        let rec attempt () =
          Rt.sleep settle_retry;
          match settle_generation t with
            | true -> attempt ()
            | false -> Atomic.set t.settle_pending false
            | exception e ->
                Atomic.set t.settle_pending false;
                Log.warn "cannot settle the collection generation: %s"
                  (Printexc.to_string e)
        in
        attempt ())

let run_job t src c _id r ~cancel:_ =
  Mutex.protect c.memo_m (fun () ->
      c.running <-
        Some
          {
            key = job_key r.job;
            file = None;
            started = Rt.now ();
            chunks = 0;
            checked = 0;
            sent = 0;
          });
  Fun.protect
    ~finally:(fun () -> Mutex.protect c.memo_m (fun () -> c.running <- None))
    (fun () ->
      run_job_body t src c r;
      match r.job with Collection_delete _ -> settle_later t | _ -> ())

let record_kind =
  {
    Dqueue.decode = decode_record;
    encode = encode_record;
    key = (fun _ -> None);
    note =
      (fun r f ->
        {
          r with
          attempts = r.attempts + 1;
          last_error = Some (Fail.kind_name f.kind, f.reason);
        });
    accepts = (fun _ -> true);
  }

let make_store t ~source_only =
  let readable = if source_only then t.mains else t.readable in
  let archives = if source_only then [] else t.archives in
  let tt = { t with readable; archives } in
  let rd ?probing f = read ?probing tt f in
  let first = match readable with m :: _ -> Some m | [] -> None in
  let write_job job f =
    if source_only then (
      let m0 = first_main t in
      let v = f m0.store in
      List.iter (fun m -> ignore (f m.store)) (List.tl t.mains);
      v)
    else write_all t job f
  in
  let batch_owner =
    match first with Some m when not source_only -> Some m | _ -> None
  in
  let batch_reachable m =
    if Health.is_down m.store.health then
      Fail.raise_ Fail.Unreachable "%s is held down" m.store.name
  in
  Store.checked
    {
      Store.name = "composite";
      put =
        (fun ?mode key body ->
          if source_only then
            List.iter (fun m -> m.store.put ?mode key body) t.mains
          else put t ?mode key body);
      put_if_absent =
        (fun key body ->
          if source_only then (first_main t).store.put_if_absent key body
          else put_if_absent t key body);
      put_if_unchanged =
        (fun key body expected ->
          put_if_unchanged t ~fill_copies:(not source_only) key body expected);
      get_opt = (fun key -> rd (fun s -> s.get_opt key));
      get_range = (fun key off len -> rd (fun s -> s.get_range key off len));
      head_opt = (fun key -> rd (fun s -> s.head_opt key));
      compute_checksum = (fun key algo -> compute_checksum tt key algo);
      delete = (fun key -> write_job (Delete key) (fun s -> s.delete key));
      delete_multi =
        (fun keys ->
          write_job (Delete_many keys) (fun s -> s.delete_multi keys));
      copy =
        (fun src dst -> write_job (Copy (src, dst)) (fun s -> s.copy src dst));
      list_prefix =
        (fun ?max_keys p ->
          match rd (fun s -> Some (s.list_prefix ?max_keys p)) with
            | Some l -> l
            | None -> []);
      watch =
        (fun key last ->
          ignore
            (rd ~probing:false (fun s ->
                 s.watch key last;
                 Some ())));
      (* A batch read of a member held down answers nothing: reading that as
         every key absent would turn live folders into orphans. *)
      get_many =
        Option.bind batch_owner (fun m ->
            Option.map
              (fun f keys ->
                batch_reachable m;
                f keys)
              m.store.get_many);
      list_many =
        Option.bind batch_owner (fun m ->
            Option.map
              (fun f ps ->
                batch_reachable m;
                f ps)
              m.store.list_many);
      bucket_functions = false;
      capabilities =
        (fun p ->
          let asked =
            List.filter_map
              (fun m ->
                if m.role = Read_only || Health.is_held m.store.health then None
                else (try Some (m, m.store.capabilities p) with _ -> None))
              (t.mains @ List.map (fun c -> c.member) t.copies)
          in
          let from_main = List.find_opt (fun (m, _) -> m.role = Main) asked in
          (match (from_main, t.mains) with
            | None, _ :: _ -> Fail.raise_ Fail.Unreachable "no main answered"
            | _ -> ());
          let readable_caps =
            List.filter
              (fun (m, _) -> List.exists (fun r -> r.name = m.name) t.readable)
              asked
          in
          {
            Store.share_url =
              Option.bind from_main (fun (_, c) -> c.Store.share_url);
            chunk_size =
              Option.bind from_main (fun (_, c) -> c.Store.chunk_size);
            max_concurrency =
              List.fold_left
                (fun acc (_, c) ->
                  match (acc, c.Store.max_concurrency) with
                    | Some a, Some b -> Some (min a b)
                    | None, b -> b
                    | a, None -> a)
                None readable_caps;
            verified =
              asked <> []
              && List.length asked
                 = List.length (t.mains @ List.map (fun c -> c.member) t.copies)
              && List.for_all
                   (fun (m, c) -> c.Store.verified || confirmed t m)
                   asked;
          });
      (* The member a read reaches now: the first not held down. *)
      fast_read =
        (fun () ->
          match
            List.find_opt
              (fun m -> not (Health.is_held m.store.health))
              readable
          with
            | Some m -> m.store.fast_read ()
            | None -> false);
      locality =
        (match first with Some m -> m.store.locality | None -> Store.Remote);
      local_path = None;
      health = Health.always_up;
      traffic = None;
    }

(* replication §7 DISCARD_POLL; object-store-common §7 PROBE_POLL and
   FUNCTION_PROBE_WAIT. *)
let default_timing = { discard_poll = 60.; probe_poll = 5.; probe_wait = 180. }

let create ?(timing = default_timing) ~domain ~data_dir ~owner ~poke ~knowledge
    members =
  let mains = List.filter (fun m -> m.role = Main) members in
  let archives = List.filter (fun m -> m.role = Read_only) members in
  let copy_members =
    List.filter (fun m -> m.role = Replica) members
    @ List.filter (fun m -> m.role = Backfill) members
  in
  let generation () =
    Gc_generation.read_mains (List.map (fun m -> m.store) mains) domain
  in
  let member_dir m =
    List.fold_left Filename.concat data_dir
      ["deferred-pending"; Domain_name.to_string domain; escape_name m.name]
  in
  let functions =
    List.filter_map
      (fun m ->
        if m.store.bucket_functions then
          Some (m.name, Bucket_function.open_ ~path:(member_dir m ^ ".function"))
        else None)
      (mains @ copy_members)
  in
  let copies =
    List.map
      (fun m ->
        let dir = member_dir m in
        let records = Dqueue.Records.open_ dir in
        {
          member = m;
          reads_reach = m.role = Replica;
          records;
          queue =
            Dqueue.create
              ~name:(Printf.sprintf "copy %s" m.name)
              ~ordered:true record_kind records;
          memo_m = Mutex.create ();
          memo = Copy_memo.create ~generation ();
          forwards = Rt.Semaphore.create ~name:"forwards" max_forwards;
          discards = Discards.open_ ~dir;
          running = None;
        })
      copy_members
  in
  let readable =
    mains
    @ List.filter_map
        (fun c -> if c.reads_reach then Some c.member else None)
        copies
  in
  let t =
    {
      domain;
      mains;
      archives;
      copies;
      functions;
      readable;
      owner;
      poke;
      knowledge;
      heard = Hashtbl.create 4;
      heard_m = Mutex.create ();
      settle_pending = Atomic.make false;
      timing;
    }
  in
  {
    core = t;
    source_store = make_store t ~source_only:true;
    whole = make_store t ~source_only:false;
  }

let store t = t.whole
let source t = t.source_store
let domain t = t.core.domain

let members t =
  t.core.mains @ List.map (fun c -> c.member) t.core.copies @ t.core.archives

let readable t = t.core.readable

let in_read_order t =
  List.stable_sort
    (fun a b -> compare (read_rank a.role) (read_rank b.role))
    (members t)

(* replication §4.8: once a request is gone, every deleted key the main still
   holds is put back before the deletion counts as settled. *)
let check_discards t src c =
  match Discards.pending c.discards with
    | [] -> ()
    | pending ->
        guard t c.member.role ("check discard requests on " ^ c.member.name);
        List.iter
          (fun (id, (p : Discards.pending)) ->
            if c.member.store.head_opt (Discards.request_key t.domain p) = None
            then (
              List.iter
                (fun k ->
                  match Key.of_string k with
                    | Some k when main_holds src k -> sync t src c k 0
                    | _ -> ())
                p.keys;
              if Discards.remove c.discards id ~seen:p then settle_later t))
          pending

let poll_discards t src =
  let rec loop () =
    Rt.sleep t.timing.discard_poll;
    List.iter
      (fun c ->
        try check_discards t src c with
          | (Stop.Stopping | Rt.Cancelled) as e -> raise e
          | e ->
              Log.warn "discard requests on %s: %s" c.member.name
                (Printexc.to_string e))
      t.copies;
    loop ()
  in
  loop ()

let probe_shard = "000"

(* object-store-common §3: an empty request of its own name, which a deployed
   function consumes; still there after FUNCTION_PROBE_WAIT, it is removed and
   nothing is saved. *)
let run_probe t m =
  let key =
    Key.discard_job t.domain ~run:(Key.probe_run ()) ~shard:probe_shard
  in
  m.store.put key Bigstring.empty;
  let deadline = Rt.now () +. t.timing.probe_wait in
  let rec wait () =
    if m.store.head_opt key = None then true
    else if Rt.now () > deadline then false
    else (
      Rt.sleep t.timing.probe_poll;
      wait ())
  in
  (* Pitfall C-7.10: an unconfirmed probe is taken back, also when the wait
     raises; a store with no function would keep it for good. *)
  let confirmed =
    match wait () with
      | c -> c
      | exception e ->
          (try ignore (m.store.delete key) with _ -> ());
          raise e
  in
  if not confirmed then ignore (m.store.delete key);
  Log.info "bucket function of %s: %s" m.name
    (if confirmed then "confirmed" else "not confirmed");
  confirmed

let probe_member t m f =
  guard t m.role ("probe the bucket function of " ^ m.name);
  Bucket_function.probe f (fun () -> run_probe t m)

let probe_due t =
  List.iter
    (fun m ->
      match function_of t m with
        | Some f when Bucket_function.due f ->
            Rt.spawn ~name:"probe bucket function" (fun () ->
                try ignore (probe_member t m f) with
                  | (Stop.Stopping | Rt.Cancelled) as e -> raise e
                  | e ->
                      Log.warn "probe of %s: %s" m.name (Printexc.to_string e))
        | _ -> ())
    (t.mains @ List.map (fun c -> c.member) t.copies)

let start ?(paused = false) (t : t) =
  if t.core.owner then (
    settle_later t.core;
    List.iter
      (fun c -> Dqueue.start ~paused c.queue (run_job t.core t.source_store c))
      t.core.copies;
    if t.core.functions <> [] then
      Rt.spawn ~name:"bucket function probes" (fun () ->
          let rec loop () =
            probe_due t.core;
            Stop.sleep 3600.;
            loop ()
          in
          loop ());
    if List.exists (fun c -> c.member.store.bucket_functions) t.core.copies then
      Rt.spawn ~name:"discard requests" (fun () ->
          poll_discards t.core t.source_store))

let rescan t = List.iter (fun c -> Dqueue.rescan c.queue) t.core.copies

let rearm t =
  List.fold_left (fun acc c -> acc + Dqueue.rearm c.queue) 0 t.core.copies

let pause t = List.iter (fun c -> Dqueue.pause c.queue) t.core.copies
let resume t = List.iter (fun c -> Dqueue.resume c.queue) t.core.copies

let settle ?timeout t =
  Rt.iter_concurrently (fun c -> Dqueue.settle ?timeout c.queue) t.core.copies;
  if t.core.owner then (
    try ignore (settle_generation t.core)
    with e ->
      Log.warn "cannot settle the collection generation: %s"
        (Printexc.to_string e))

type job_progress = {
  job : string;
  file : (string * int) option;
  elapsed : float;
  chunks : int;
  checked : int;
  sent : int;
}

type copy_stats = {
  copy : string;
  owed : int;
  parked : int;
  done_ : int;
  current : job_progress option;
}

let copy_stats t =
  List.map
    (fun c ->
      {
        copy = c.member.name;
        owed = Dqueue.pending c.queue;
        parked = List.length (Dqueue.parked c.queue);
        done_ = Dqueue.completed c.queue;
        current =
          Mutex.protect c.memo_m (fun () ->
              Option.map
                (fun (r : running) ->
                  {
                    job = r.key;
                    file = r.file;
                    elapsed = Rt.now () -. r.started;
                    chunks = r.chunks;
                    checked = r.checked;
                    sent = r.sent;
                  })
                c.running);
      })
    t.core.copies

let parked t =
  List.concat_map
    (fun c ->
      List.map (fun (id, n) -> (c.member.name, id, n)) (Dqueue.parked c.queue))
    t.core.copies

let guard t (m : member) what = guard t.core m.role what

let submit_collection_delete t (m : member) ~keys ~run ~shard ~generation =
  List.iter
    (fun c ->
      if c.member.name = m.name then
        submit t.core c (Collection_delete { keys; run; shard; generation }))
    t.core.copies

let collection_owed t ~generation = collection_owed t.core ~generation ()
let function_confirmed t m = confirmed t.core m

(* object-store-common §3: one request per shard, populated or not; listing
   which shards exist would cost more than the empty requests. *)
let queue_verification ?(cancelled = Fun.const false) t m =
  if not (confirmed t.core m) then `Unsupported
  else (
    guard t m ("queue verification on " ^ m.name);
    (* Eight at a time: one after another is ten minutes of empty puts. *)
    let written = Atomic.make 0 in
    ignore
      (Cancel.batches ~size:64 cancelled
         (Rt.iter_bounded ~width:8 (fun shard ->
              m.store.put (Key.verify_job t.core.domain shard) Bigstring.empty;
              Atomic.incr written))
         (List.init 4096 (Printf.sprintf "%03x")));
    `Queued (Atomic.get written))

(* A cancel stops the waiting only: the probe runs on in its own fiber, since
   other callers may share its answer. *)
let probe ?(cancelled = Fun.const false) t m =
  match function_of t.core m with
    | Some f ->
        let answer = Rt.async (fun () -> probe_member t.core m f) in
        Cancel.race cancelled (fun () -> Rt.Promise.await answer)
    | None -> false

type outstanding = { copy : string; request : Key.t; keys : int; age : float }

let requests ?(probes = true) c d =
  List.filter
    (fun (e : Store.entry) ->
      match Key.parse_discard_job e.key with
        | Some (_, run, _) -> probes || not (Key.is_probe_run run)
        | None -> false)
    (c.member.store.list_prefix (Key.gc_jobs d))

let outstanding t =
  let now = Unix.gettimeofday () in
  List.concat_map
    (fun c ->
      if not c.member.store.bucket_functions then []
      else
        List.map
          (fun (e : Store.entry) ->
            {
              copy = c.member.name;
              request = e.key;
              keys =
                List.length
                  (Option.fold ~none:[] ~some:Discards.keys_of_body
                     (c.member.store.get_opt e.key));
              age = now -. e.last_modified;
            })
          (requests ~probes:false c t.core.domain))
    t.core.copies

(* gc §5.7 re-delivery: only the keys still absent from the collected main,
   which raises a fresh notification; a request left with none is deleted. A
   probe's request is its prober's to remove. *)
let retry_outstanding t =
  List.fold_left
    (fun n c ->
      if not c.member.store.bucket_functions then n
      else (
        guard t c.member ("re-deliver requests to " ^ c.member.name);
        (* A probe's request outlives it only when its prober died or could
           not delete it: past twice the probe's wait, it is nobody's. *)
        let now = Unix.gettimeofday () in
        List.iter
          (fun (e : Store.entry) ->
            match Key.parse_discard_job e.key with
              | Some (_, run, _)
                when Key.is_probe_run run
                     && now -. e.last_modified > 2. *. t.core.timing.probe_wait
                ->
                  ignore (c.member.store.delete e.key)
              | _ -> ())
          (requests c t.core.domain);
        List.fold_left
          (fun n (e : Store.entry) ->
            match c.member.store.get_opt e.key with
              | None -> n
              | Some b ->
                  (match
                     List.filter
                       (fun k -> not (main_holds t.source_store k))
                       (Discards.keys_of_body b)
                   with
                    | [] -> ignore (c.member.store.delete e.key)
                    | keys ->
                        c.member.store.put e.key
                          (Discards.body (List.map Key.to_string keys)));
                  n + 1)
          n
          (requests ~probes:false c t.core.domain)))
    0 t.core.copies
