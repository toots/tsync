open Tsync_core

let read_deadline = 15.
let touch_interval = 60.
let default_cache_chunk_size = 16 * 1024 * 1024

type member = { index : int; ck : Chunk_key.t; len : int; off : int }
type group = { gkey : string; members : member list; gsize : int }

let per ~cs ~cc = if cs <= 0 then 1 else max 1 ((cc + (cs / 2)) / cs)

(* 04 §2.2: the digest of the member keys, never first and last alone. *)
let group_key keys =
  let st = Xxh.dual_create () in
  List.iter
    (fun k ->
      let s = Chunk_key.to_string k ^ ";" in
      Xxh.dual_update_string st s 0 (String.length s))
    keys;
  Xxh.dual_digest st

let group_of ~cc (m : Manifest.t) g =
  let per = per ~cs:m.chunk_size ~cc in
  let first = g * per in
  let last = min m.count (first + per) - 1 in
  let members =
    List.init
      (last - first + 1)
      (fun j ->
        let i = first + j in
        {
          index = i;
          ck = Manifest.key m i;
          len = Chunking.length ~size:m.size ~cs:m.chunk_size i;
          off = j * m.chunk_size;
        })
  in
  {
    gkey = group_key (List.map (fun x -> x.ck) members);
    members;
    gsize = List.fold_left (fun a x -> a + x.len) 0 members;
  }

let groups ~cc (m : Manifest.t) =
  if m.link <> None || m.count = 0 then []
  else (
    let per = per ~cs:m.chunk_size ~cc in
    List.init ((m.count + per - 1) / per) (group_of ~cc m))

let group_index ~cc (m : Manifest.t) i = i / per ~cs:m.chunk_size ~cc

type gstate = {
  lock : Rt.Fmutex.t;
  mutable generation : int;
  held : (int, int * int) Hashtbl.t;
  mutable from_ranges : int list;
}

type counts = { bytes : int; pinned : int; bodies : int }

type t = {
  dir : string;
  cc : int;
  fast : unit -> bool;
  get_whole : Chunk_key.t -> Bigstring.t;
  get_range : Chunk_key.t -> int -> int -> Bigstring.t;
  m : Mutex.t;
  states : (string, gstate) Hashtbl.t;
  in_flight : (string, unit Rt.Promise.t) Hashtbl.t;
  mutable links : [ `Unknown | `Yes | `No ];
  cap : int option;
  last : counts option Atomic.t;
}

let create ~cache_root ~domain ~cc ~fast ~get_whole ~get_range ~cap =
  {
    dir =
      Filename.concat
        (Filename.concat cache_root (Domain_name.to_string domain))
        "chunks";
    cc;
    fast;
    get_whole;
    get_range;
    m = Mutex.create ();
    states = Hashtbl.create 256;
    in_flight = Hashtbl.create 16;
    links = `Unknown;
    cap;
    last = Atomic.make None;
  }

let cc t = t.cc
let shard_dir t gkey = Filename.concat t.dir (Names.shard gkey)
let whole_path t gkey = Filename.concat (shard_dir t gkey) gkey
let partial_path t gkey = whole_path t gkey ^ ".partial"
let pin_path t gkey = whole_path t gkey ^ ".pin"
let is_whole t gkey = Fs.exists (whole_path t gkey)

let state t gkey =
  Mutex.protect t.m (fun () ->
      match Hashtbl.find_opt t.states gkey with
        | Some s -> s
        | None ->
            let s =
              {
                lock = Rt.Fmutex.create ();
                generation = 0;
                held = Hashtbl.create 2;
                from_ranges = [];
              }
            in
            Hashtbl.replace t.states gkey s;
            s)

let forget s =
  Hashtbl.reset s.held;
  s.from_ranges <- [];
  s.generation <- s.generation + 1

(* The work runs detached; a reader waits at most [read_deadline] and the
   work lands for the next reader. *)
let within_deadline f =
  let p = Rt.Promise.create () in
  Rt.spawn ~name:"cache fetch" (fun () ->
      match f () with
        | v -> ignore (Rt.Promise.try_resolve p v)
        | exception e -> Rt.Promise.fail p e);
  try Rt.with_timeout read_deadline (fun () -> Rt.Promise.await p)
  with Rt.Timeout ->
    Fail.raise_ Fail.Deadline "no answer within %.0fs" read_deadline

let fetch_verified t (x : member) =
  let b = t.get_whole x.ck in
  if
    Bigstring.length b <> x.len
    || not (Chunk_key.equal (Chunk_key.of_bigstring b) x.ck)
  then
    Fail.corrupt "chunk %s: %d bytes that do not hash to its key"
      (Chunk_key.to_string x.ck) (Bigstring.length b);
  b

let write_at fd ~off b =
  Fs.pwrite_all fd b ~boff:0 ~len:(Bigstring.length b) ~off

let rec ensure_whole ?(force = false) t g =
  let p = Mutex.protect t.m (fun () -> Hashtbl.find_opt t.in_flight g.gkey) in
  match p with
    | Some p -> Rt.Promise.await p
    | None ->
        let p = Rt.Promise.create () in
        let mine =
          Mutex.protect t.m (fun () ->
              if Hashtbl.mem t.in_flight g.gkey then false
              else (
                Hashtbl.replace t.in_flight g.gkey p;
                true))
        in
        if not mine then ensure_whole ~force t g
        else
          Fun.protect
            ~finally:(fun () ->
              Mutex.protect t.m (fun () -> Hashtbl.remove t.in_flight g.gkey);
              ignore (Rt.Promise.try_resolve p ()))
            (fun () -> if force || not (is_whole t g.gkey) then fetch_group t g)

(* 04 §2.7: a whole body is created only verified, data fsynced, renamed. *)
and fetch_group t g =
  Fs.mkdir_p (shard_dir t g.gkey);
  let tmp = Fs.temp_in (shard_dir t g.gkey) in
  let fd = Fs.openfile tmp [O_WRONLY; O_CREAT; O_EXCL] in
  (try
     Fs.with_fd fd (fun fd ->
         Fs.reserve fd g.gsize;
         List.iter
           (fun x -> write_at fd ~off:x.off (fetch_verified t x))
           g.members;
         Fs.fsync fd)
   with e ->
     Fs.unlink_quiet tmp;
     raise e);
  let s = state t g.gkey in
  Rt.Fmutex.with_lock s.lock (fun () ->
      Fs.rename tmp (whole_path t g.gkey);
      Fs.unlink_quiet (partial_path t g.gkey);
      forget s)

(* read-path §4.4: one interval per member; a gap is fetched rather than an
   interval split. *)
let missing have (c, dd) =
  match have with
    | None -> Some (c, dd)
    | Some (a, b) ->
        if c >= a && dd <= b then None
        else if dd <= a then Some (c, a)
        else if c >= b then Some (b, dd)
        else if c < a && dd > b then Some (c, dd)
        else if c < a then Some (c, a)
        else Some (b, dd)

let widen have (lo, hi) =
  match have with
    | None -> (lo, hi)
    | Some (a, b) ->
        if hi >= a && lo <= b then (min a lo, max b hi)
        else if hi - lo > b - a then (lo, hi)
        else (a, b)

(* Every member read back from a range-built body is verified before the body
   is installed whole. Must hold the group's lock. *)
let install_from_partial t g s =
  let pp = partial_path t g.gkey in
  let ok =
    List.for_all
      (fun x ->
        (not (List.mem x.index s.from_ranges))
        ||
          match Fs.open_nofollow pp with
          | None -> false
          | Some fd ->
              Fs.with_fd fd (fun fd ->
                  let buf = Bigstring.create x.len in
                  let n = Fs.pread_full fd buf ~boff:0 ~len:x.len ~off:x.off in
                  n = x.len && Chunk_key.equal (Chunk_key.of_bigstring buf) x.ck))
      g.members
  in
  if ok then (
    Fs.with_fd (Fs.openfile pp [O_RDONLY]) Fs.fsync;
    Fs.rename pp (whole_path t g.gkey);
    forget s;
    `Installed)
  else (
    Fs.unlink_quiet pp;
    forget s;
    `Mismatch)

let pread_path p ~off ~len =
  match Fs.open_nofollow p with
    | None -> None
    | Some fd ->
        Fs.with_fd fd (fun fd ->
            let buf = Bigstring.create len in
            let n = Fs.pread_full fd buf ~boff:0 ~len ~off in
            Some (Bigstring.sub buf ~off:0 ~len:n))

let all_held g s =
  List.for_all
    (fun x -> x.len = 0 || Hashtbl.find_opt s.held x.index = Some (0, x.len))
    g.members

let rec fill t g (x : member) (c, dd) =
  let s = state t g.gkey in
  let plan =
    Rt.Fmutex.with_lock s.lock (fun () ->
        if is_whole t g.gkey then `Whole
        else (
          match missing (Hashtbl.find_opt s.held x.index) (c, dd) with
            | None ->
                `Bytes
                  (Option.value ~default:Bigstring.empty
                     (pread_path (partial_path t g.gkey) ~off:(x.off + c)
                        ~len:(dd - c)))
            | Some gap ->
                if not (Fs.exists (partial_path t g.gkey)) then (
                  Fs.mkdir_p (shard_dir t g.gkey);
                  Fs.with_fd
                    (Fs.openfile (partial_path t g.gkey) [O_WRONLY; O_CREAT])
                    (fun _ -> ());
                  Hashtbl.reset s.held;
                  s.from_ranges <- []);
                `Fetch (s.generation, gap)))
  in
  match plan with
    | `Whole -> `Whole
    | `Bytes b -> `Bytes b
    | `Fetch (gen, (lo, hi)) -> (
        let data = t.get_range x.ck lo (hi - lo) in
        let r =
          Rt.Fmutex.with_lock s.lock (fun () ->
              if s.generation <> gen || not (Fs.exists (partial_path t g.gkey))
              then `Again
              else (
                Fs.with_fd
                  (Fs.openfile (partial_path t g.gkey) [O_WRONLY])
                  (fun fd -> write_at fd ~off:(x.off + lo) data);
                Hashtbl.replace s.held x.index
                  (widen
                     (Hashtbl.find_opt s.held x.index)
                     (lo, lo + Bigstring.length data));
                if not (List.mem x.index s.from_ranges) then
                  s.from_ranges <- x.index :: s.from_ranges;
                if all_held g s then (
                  match install_from_partial t g s with
                    | `Installed -> `Whole
                    | `Mismatch -> `Mismatch)
                else if
                  Hashtbl.find_opt s.held x.index
                  |> Option.fold ~none:false ~some:(fun (a, b) ->
                      a <= c && dd <= b)
                then
                  `Bytes
                    (Option.value ~default:Bigstring.empty
                       (pread_path (partial_path t g.gkey) ~off:(x.off + c)
                          ~len:(dd - c)))
                else `Again))
        in
        match r with
          | `Again -> fill t g x (c, dd)
          | `Mismatch ->
              ensure_whole ~force:true t g;
              `Whole
          | (`Whole | `Bytes _) as r -> r)

let touch t gkey =
  let p = whole_path t gkey in
  match Fs.stat_opt p with
    | Some st when Unix.gettimeofday () -. st.st_mtime > touch_interval -> (
        try Unix.utimes p 0. 0. with _ -> ())
    | _ -> ()

(* read-path §4.3: a demand read never waits for another's whole fetch on a
   slow store; a body replaced under a reader is refetched once. *)
let read_piece t (g : group) (x : member) ~coff ~len =
  let from_body () =
    match pread_path (whole_path t g.gkey) ~off:(x.off + coff) ~len with
      | Some s when Bigstring.length s = len ->
          touch t g.gkey;
          Some s
      | _ -> None
  in
  let attempt () =
    let r =
      within_deadline (fun () ->
          if is_whole t g.gkey then `Whole
          else if t.fast () then (
            ensure_whole t g;
            `Whole)
          else fill t g x (coff, coff + len))
    in
    match r with
      | `Bytes b -> b
      | `Whole -> (
          match from_body () with Some s -> s | None -> Bigstring.empty)
  in
  let s = attempt () in
  if Bigstring.length s = len then s
  else (
    within_deadline (fun () -> ensure_whole ~force:true t g);
    match from_body () with
      | Some s -> s
      | None -> Fail.corrupt "cache body %s is short" g.gkey)

(* A whole, verified body is the only source of inherited bytes that leave the
   machine in a new publication. *)
let verified_member t g (x : member) =
  ensure_whole t g;
  match pread_path (whole_path t g.gkey) ~off:x.off ~len:x.len with
    | Some s when Bigstring.length s = x.len -> s
    | _ -> Fail.corrupt "cache body %s is short" g.gkey

let evict_group t gkey =
  let s = state t gkey in
  if Rt.Fmutex.is_locked s.lock then false
  else
    Rt.Fmutex.with_lock s.lock (fun () ->
        Fs.unlink_quiet (whole_path t gkey);
        Fs.unlink_quiet (partial_path t gkey);
        Fs.unlink_quiet (pin_path t gkey);
        forget s;
        true)

let evict t (m : Manifest.t) =
  List.iter (fun g -> ignore (evict_group t g.gkey)) (groups ~cc:t.cc m)

let unpin t (m : Manifest.t) =
  List.iter (fun g -> Fs.unlink_quiet (pin_path t g.gkey)) (groups ~cc:t.cc m)

(* read-path §4.8: pins are durable before the fetch, so the cap cannot take a
   group between its fetch and its pin. *)
let pin t (m : Manifest.t) ~until =
  let gs = groups ~cc:t.cc m in
  List.iter
    (fun g ->
      Fs.mkdir_p (shard_dir t g.gkey);
      let p = pin_path t g.gkey in
      if not (Fs.exists p) then Fs.durable_replace p "";
      Unix.utimes p until until)
    gs;
  List.iter (fun g -> ensure_whole t g) gs

let availability t (m : Manifest.t) =
  let gs = groups ~cc:t.cc m in
  if gs = [] then `Cached
  else if not (List.for_all (fun g -> is_whole t g.gkey) gs) then `Online_only
  else (
    let now = Unix.gettimeofday () in
    let pins =
      List.map
        (fun g ->
          match Fs.stat_opt (pin_path t g.gkey) with
            | Some st when st.st_mtime >= now -> Some st.st_mtime
            | _ -> None)
        gs
    in
    if List.for_all Option.is_some pins then
      `Pinned (List.fold_left (fun a p -> min a (Option.get p)) infinity pins)
    else `Cached)

let resident t (m : Manifest.t) =
  let gs = groups ~cc:t.cc m in
  (List.length (List.filter (fun g -> is_whole t g.gkey) gs), List.length gs)

(* 04 §4.8: the promoted staged body becomes a second name of the same inode. *)
let adopt_body t gkey source =
  Fs.mkdir_p (shard_dir t gkey);
  let s = state t gkey in
  Rt.Fmutex.with_lock s.lock (fun () ->
      Fs.unlink_quiet (partial_path t gkey);
      forget s;
      (* ponytail: a root that cannot link copies through the heap; rare, and
         bounded by one group. *)
      let copy () =
        let data = Fs.read_file source in
        let tmp = Fs.write_temp (shard_dir t gkey) data in
        Fs.rename tmp (whole_path t gkey)
      in
      (match t.links with
        | `No -> copy ()
        | _ -> (
            match Fs.eintr (fun () -> Unix.link source (whole_path t gkey)) with
              | () -> t.links <- `Yes
              | exception Unix.Unix_error (Unix.EEXIST, _, _) -> ()
              | exception
                  Unix.Unix_error
                    ( ( Unix.EPERM | Unix.ENOSYS | Unix.EOPNOTSUPP | Unix.EXDEV
                      | Unix.EMLINK ),
                      _,
                      _ ) ->
                  t.links <- `No;
                  copy ()
              | exception Unix.Unix_error (e, fn, a) ->
                  raise (Fail.E (Fail.of_unix e fn a))));
      try
        let now = Unix.gettimeofday () in
        Unix.utimes (whole_path t gkey) now now
      with _ -> ())

let is_group_key n = Names.is_chunk_key n

(* 04 §4.10 step 2: only whole bodies and pins survive an owner start, each
   body removed before its companions. *)
let sweep_at_start t =
  List.iter
    (fun shard ->
      let dir = Filename.concat t.dir shard in
      let names = Fs.readdir dir in
      let bodies = List.filter is_group_key names in
      List.iter
        (fun b ->
          if
            List.exists
              (fun n ->
                String.starts_with ~prefix:(b ^ ".") n && n <> b ^ ".pin")
              names
          then Fs.unlink_quiet (Filename.concat dir b))
        bodies;
      List.iter
        (fun n ->
          let keep =
            is_group_key n
            || String.ends_with ~suffix:".pin" n
               && is_group_key (Filename.chop_suffix n ".pin")
          in
          if not keep then Fs.rm_rf (Filename.concat dir n))
        (Fs.readdir dir))
    (Fs.readdir t.dir)

(* read-path §4.9: lapsed pins go, then the coldest unpinned bodies until the
   unpinned bytes fit the cap. *)
let enforce_cap t =
  let now = Unix.gettimeofday () in
  let bodies = ref [] and pinned = ref 0 and total = ref 0 in
  let count = ref 0 in
  List.iter
    (fun shard ->
      let dir = Filename.concat t.dir shard in
      List.iter
        (fun n ->
          let p = Filename.concat dir n in
          if String.ends_with ~suffix:".pin" n then (
            match Fs.stat_opt p with
              | Some st when st.st_mtime < now -> Fs.unlink_quiet p
              | _ -> ())
          else (
            match Fs.lstat_opt p with
              | Some st when st.st_kind = S_REG ->
                  let gkey =
                    if String.ends_with ~suffix:".partial" n then
                      Filename.chop_suffix n ".partial"
                    else n
                  in
                  let bytes = Int64.to_int st.st_size in
                  let live_pin =
                    match Fs.stat_opt (pin_path t gkey) with
                      | Some ps -> ps.st_mtime >= now
                      | None -> false
                  in
                  total := !total + bytes;
                  incr count;
                  if live_pin then pinned := !pinned + bytes
                  else bodies := (st.st_mtime, gkey, bytes) :: !bodies
              | _ -> ()))
        (Fs.readdir dir))
    (Fs.readdir t.dir);
  (match t.cap with
    | Some cap ->
        let over = ref (!total - !pinned - cap) in
        List.iter
          (fun (_, gkey, bytes) ->
            if !over > 0 && evict_group t gkey then (
              over := !over - bytes;
              decr count;
              total := !total - bytes))
          (List.sort compare !bodies)
    | None -> ());
  let counts = { bytes = !total; pinned = !pinned; bodies = !count } in
  Atomic.set t.last (Some counts);
  counts

let last_counts t = Atomic.get t.last
let cap t = t.cap
