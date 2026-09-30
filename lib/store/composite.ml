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

type knowledge = {
  chunk_names : Bigstring.t -> Chunk_key.t list;
  generation : unit -> int option;
  is_index : Key.t -> bool;
  is_journal : Key.t -> bool;
}

type copy = {
  member : member;
  reads_reach : bool;
  records : Dqueue.Records.t;
  queue : record Dqueue.t;
  memo_m : Mutex.t;
  ensured : (string, int) Hashtbl.t;
  known_shards : (string, int) Hashtbl.t;
  forwards : Rt.Semaphore.t;
}

type core = {
  domain : Domain_name.t;
  mains : member list;
  archives : member list;
  copies : copy list;
  readable : member list;
  owner : bool;
  poke : unit -> unit;
  knowledge : knowledge;
  heard : (string, unit) Hashtbl.t;
  heard_m : Mutex.t;
}

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
        | Some job ->
            let r = { job; attempts = 0; last_error = None } in
            if t.owner then ignore (Dqueue.post c.queue r)
            else (
              ignore (Dqueue.Records.create c.records (encode_record r));
              t.poke ()))
    t.copies

let generation_even t =
  match t.knowledge.generation () with
    | Some g when g mod 2 = 0 -> Some g
    | _ -> None

let relies c g k =
  match g with
    | None -> false
    | Some g ->
        Mutex.protect c.memo_m (fun () ->
            Hashtbl.find_opt c.ensured (Chunk_key.to_string k) = Some g)

let note c g k =
  match g with
    | Some g ->
        Mutex.protect c.memo_m (fun () ->
            Hashtbl.replace c.ensured (Chunk_key.to_string k) g)
    | None -> ()

(* A best-effort forward of a chunk to a copy: never blocks the writer, and a
   forward that does not happen is fetched by the manifest's job. *)
let forward_chunk t c key body =
  match Key.chunk_of key with
    | None -> ()
    | Some ck ->
        let g = generation_even t in
        if (not (relies c g ck)) && Rt.Semaphore.try_acquire c.forwards then
          Rt.spawn ~name:"forward" (fun () ->
              Fun.protect
                ~finally:(fun () -> Rt.Semaphore.release c.forwards)
                (fun () ->
                  match c.member.store.put ~mode:Store.Best_effort key body with
                    | () -> note c g ck
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
      (fun c -> if not (skip t c key) then forward_chunk t c key body)
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

let write_all t job f =
  let m0 = first_main t in
  let v = f m0.store in
  fill t job;
  List.iter (fun m -> ignore (f m.store)) (List.tl t.mains);
  v

let probe_main t m =
  match
    Rt.with_timeout Health.probe_timeout (fun () ->
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

let rec sync t src c key restarts =
  match src.Store.get_opt key with
    | None ->
        (match Key.chunk_of key with
          | Some ck ->
              Mutex.protect c.memo_m (fun () ->
                  Hashtbl.remove c.ensured (Chunk_key.to_string ck))
          | None -> ());
        ignore (c.member.store.delete key)
    | Some b -> (
        let g = generation_even t in
        let missing =
          List.find_opt
            (fun ck -> not (ensure_chunk t src c g ck))
            (t.knowledge.chunk_names b)
        in
        match missing with
          | None -> c.member.store.put key b
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

and ensure_chunk t (src : Store.t) c g ck =
  let d = t.domain in
  if relies c g ck then true
  else (
    let known =
      match g with
        | Some g ->
            let sss = Chunk_key.shard ck in
            if
              Mutex.protect c.memo_m (fun () ->
                  Hashtbl.find_opt c.known_shards sss <> Some g)
            then (
              let listing =
                c.member.store.list_prefix (Key.shard_prefix d sss)
              in
              Mutex.protect c.memo_m (fun () ->
                  List.iter
                    (fun (e : Store.entry) ->
                      Hashtbl.replace c.ensured (Key.leaf e.key) g)
                    listing;
                  Hashtbl.replace c.known_shards sss g));
            relies c (Some g) ck
        | None -> c.member.store.head_opt (Key.chunk d ck) <> None
    in
    known
    ||
    let body =
      match src.get_opt (Key.chunk d ck) with
        | Some b -> Some b
        | None -> src.get_opt (Key.chunk_from d ck)
    in
    match body with
      | None -> false
      | Some b ->
          c.member.store.put (Key.chunk d ck) b;
          note c g ck;
          true)

let main_holds t (src : Store.t) key =
  match Key.chunk_of key with
    | Some ck ->
        src.head_opt (Key.chunk t.domain ck) <> None
        || src.head_opt (Key.chunk_from t.domain ck) <> None
    | None -> src.head_opt key <> None

let run_job t src c _id r ~cancel:_ =
  guard t c.member.role ("copy to " ^ c.member.name);
  match r.job with
    | Put k | Delete k -> sync t src c k 0
    | Copy (_, d) -> sync t src c d 0
    | Delete_many ks -> List.iter (fun k -> sync t src c k 0) ks
    | Collection_delete cd ->
        let ks = List.filter (fun k -> not (main_holds t src k)) cd.keys in
        Mutex.protect c.memo_m (fun () ->
            List.iter (fun k -> Hashtbl.remove c.ensured (Key.leaf k)) ks;
            Hashtbl.clear c.known_shards);
        let markers = List.filter_map Key.marker_of ks in
        c.member.store.delete_multi (ks @ markers);
        List.iter (fun k -> if main_holds t src k then sync t src c k 0) cd.keys

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
      get_opt = (fun key -> rd (fun s -> s.get_opt key));
      get_range = (fun key off len -> rd (fun s -> s.get_range key off len));
      head_opt = (fun key -> rd (fun s -> s.head_opt key));
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
      get_many =
        Option.bind batch_owner (fun m ->
            Option.map
              (fun f keys ->
                if Health.is_down m.store.health then
                  List.map (fun _ -> None) keys
                else f keys)
              m.store.get_many);
      list_many =
        Option.bind batch_owner (fun m ->
            Option.map
              (fun f ps -> if Health.is_down m.store.health then [] else f ps)
              m.store.list_many);
      verify_all =
        (fun p ->
          let targets =
            if List.exists (fun m -> Health.is_down m.store.health) t.mains then
              t.mains
            else readable
          in
          let answers = List.map (fun m -> m.store.verify_all p) targets in
          if answers <> [] && List.for_all (( = ) `Unsupported) answers then
            `Unsupported
          else
            `Queued
              (List.fold_left
                 (fun acc -> function
                   | `Queued n -> acc + n | `Unsupported -> acc)
                 0 answers));
      discard = (fun ~chunk_prefix:_ ~run:_ ~name:_ _ -> `Unsupported);
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
              && List.for_all (fun (_, c) -> c.Store.verified) asked;
          });
      fast_read =
        (match first with Some m -> m.store.fast_read | None -> false);
      local_path = None;
      health = Health.always_up;
      traffic = None;
    }

let create ~domain ~data_dir ~owner ~poke ~knowledge members =
  let mains = List.filter (fun m -> m.role = Main) members in
  let archives = List.filter (fun m -> m.role = Read_only) members in
  let copy_members =
    List.filter (fun m -> m.role = Replica) members
    @ List.filter (fun m -> m.role = Backfill) members
  in
  let copies =
    List.map
      (fun m ->
        let dir =
          List.fold_left Filename.concat data_dir
            [
              "deferred-pending";
              Domain_name.to_string domain;
              escape_name m.name;
            ]
        in
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
          ensured = Hashtbl.create 1024;
          known_shards = Hashtbl.create 64;
          forwards = Rt.Semaphore.create ~name:"forwards" 4;
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
      readable;
      owner;
      poke;
      knowledge;
      heard = Hashtbl.create 4;
      heard_m = Mutex.create ();
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

let start ?(paused = false) (t : t) =
  if t.core.owner then
    List.iter
      (fun c -> Dqueue.start ~paused c.queue (run_job t.core t.source_store c))
      t.core.copies

let rescan t = List.iter (fun c -> Dqueue.rescan c.queue) t.core.copies

let rearm t =
  List.fold_left (fun acc c -> acc + Dqueue.rearm c.queue) 0 t.core.copies

let pause t = List.iter (fun c -> Dqueue.pause c.queue) t.core.copies
let resume t = List.iter (fun c -> Dqueue.resume c.queue) t.core.copies

let settle ?timeout t =
  Rt.iter_concurrently (fun c -> Dqueue.settle ?timeout c.queue) t.core.copies

type copy_stats = { copy : string; owed : int; parked : int; done_ : int }

let copy_stats t =
  List.map
    (fun c ->
      {
        copy = c.member.name;
        owed = Dqueue.pending c.queue;
        parked = List.length (Dqueue.parked c.queue);
        done_ = Dqueue.completed c.queue;
      })
    t.core.copies

let parked t =
  List.concat_map
    (fun c ->
      List.map (fun (id, n) -> (c.member.name, id, n)) (Dqueue.parked c.queue))
    t.core.copies

let guard t (m : member) what = guard t.core m.role what

let submit_collection_delete t (m : member) ~keys ~run ~shard ~generation =
  match List.find_opt (fun c -> c.member.name = m.name) t.core.copies with
    | None -> ()
    | Some c ->
        ignore
          (Dqueue.post c.queue
             {
               job = Collection_delete { keys; run; shard; generation };
               attempts = 0;
               last_error = None;
             })
