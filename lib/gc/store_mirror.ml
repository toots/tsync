open Tsync_core
open Tsync_store
open Tsync_remote

type scope = All | Manifests | Path of string

type copied = {
  name : string;
  checked : int;
  copied : int;
  copied_bytes : int;
  changed : int;
  unguarded : int;
  failed : (string * string) list;
}

type report = { source : string; copies : copied list; cancelled : bool }

let index_leaf = ".tsync-index"

(* One destination's tallies, shared by the batch's workers. *)
type counts = {
  m : Mutex.t;
  mutable checked : int;
  mutable copied : int;
  mutable bytes : int;
  mutable changed : int;
  mutable unguarded : int;
  mutable failed : (string * string) list;
}

let counts () =
  {
    m = Mutex.create ();
    checked = 0;
    copied = 0;
    bytes = 0;
    changed = 0;
    unguarded = 0;
    failed = [];
  }

let tally c f = Mutex.protect c.m (fun () -> f c)

let rank : Store.locality -> int = function
  | Local -> 0
  | Proxy -> 1
  | Remote -> 2

(* 05 §4.6 step 6: compare what the entries carry; else compute what the other
   side carries on the side that lacks it; else MD5 on both. Between sides
   that could both compute, the closer one does, the source on a tie. A body
   that vanished meanwhile reads as different, and the copy sorts it out. *)
let differs ~(src : Store.t) ~(dst : Store.t) (ours : Store.entry)
    (theirs : Store.entry) =
  let on (s : Store.t) (e : Store.entry) algo = s.compute_checksum e.key algo in
  let against side e (c : Checksum.t) =
    match on side e c.algo with Some x -> x <> c | None -> true
  in
  match (ours.checksum, theirs.checksum) with
    | Some a, Some b when Checksum.comparable a b -> a <> b
    | Some a, None -> against dst theirs a
    | None, Some b -> against src ours b
    | Some a, Some b ->
        if rank src.locality <= rank dst.locality then against src ours b
        else against dst theirs a
    | None, None -> (
        match (on src ours Checksum.md5, on dst theirs Checksum.md5) with
          | Some a, Some b -> a <> b
          | _ -> true)

module Make (C : Context.S) = struct
  module T = Tree.Make (C)

  let d = C.domain

  (* One batch of keys to compare and copy, listed together. Chunks are named
     by their content: compared by name and size, written plainly. *)
  type batch = {
    label : string;
    source : Store.entry list;
    chunks : bool;
    part : int * int;
        (** its place among a run of like batches (the 4096 chunk shards), so
            progress runs across the whole run, not per batch *)
  }

  (* 05 §4.6 step 7: a chunk is put; anything else replaces the entry the
     comparison read, and is put plainly only where the destination cannot
     evaluate that. *)
  let copy ~narrate ~(src : Store.t) ~(dst : Store.t) c b (e : Store.entry)
      theirs =
    match src.get_opt e.key with
      | None -> ()
      | Some body -> (
          let n = Bigstring.length body in
          let written () =
            tally c (fun c ->
                c.copied <- c.copied + 1;
                c.bytes <- c.bytes + n)
          in
          match
            if b.chunks then (
              dst.put e.key body;
              `Written)
            else (
              match dst.put_if_unchanged e.key body theirs with
                | Written -> `Written
                | Changed -> `Changed
                | exception Fail.E { kind = Refused; _ } ->
                    dst.put e.key body;
                    `Unguarded)
          with
            | outcome -> (
                Fs.drop_mapped_pages body;
                match outcome with
                  | `Written -> written ()
                  | `Unguarded ->
                      written ();
                      tally c (fun c -> c.unguarded <- c.unguarded + 1)
                  | `Changed ->
                      Narrate.say narrate
                        "  %s: %s changed since it was compared; left for the \
                         next run"
                        dst.name (Key.to_string e.key);
                      tally c (fun c -> c.changed <- c.changed + 1))
            | exception ((Stop.Stopping | Rt.Cancelled) as x) -> raise x
            | exception x ->
                let reason = (Fail.classify x).reason in
                Narrate.say narrate "  %s refused %s: %s" dst.name
                  (Key.to_string e.key) reason;
                tally c (fun c ->
                    c.failed <- (Key.to_string e.key, reason) :: c.failed))

  let report ~narrate ~(dst : Store.t) c b ~done_ ~total =
    let index, parts = b.part in
    let fraction =
      (float_of_int index
      +. if total = 0 then 1. else float_of_int done_ /. float_of_int total)
      /. float_of_int (max 1 parts)
    in
    if parts > 1 then
      Narrate.progress narrate ~fraction
        "%s: %s (%d of %d), %d checked, %d copied" dst.name b.label (index + 1)
        parts
        (c.checked + if done_ = total then 0 else done_)
        c.copied
    else
      Narrate.progress narrate ~fraction "%s: %s, %d of %d compared, %d copied"
        dst.name b.label done_ total c.copied

  let copy_batch ~narrate ~cancelled ~(src : Store.t) ~(dst : Store.t) ~listed c
      b =
    let there = Hashtbl.create 256 in
    List.iter (fun (e : Store.entry) -> Hashtbl.replace there e.key e) listed;
    let total = List.length b.source in
    let todo = ref b.source and m = Mutex.create () and seen = ref 0 in
    let next () =
      Mutex.protect m (fun () ->
          match !todo with
            | e :: rest when not (cancelled ()) ->
                todo := rest;
                Some e
            | _ -> None)
    in
    Rt.each ~width:(max 1 C.max_downloads) next (fun (e : Store.entry) ->
        let theirs = Hashtbl.find_opt there e.key in
        let changed =
          match theirs with
            | None -> true
            | Some x when x.size <> e.size -> true
            | Some _ when b.chunks -> false
            | Some x -> differs ~src ~dst e x
        in
        if changed then copy ~narrate ~src ~dst c b e theirs;
        (* reported under the lock, so the count never runs backwards *)
        Mutex.protect m (fun () ->
            incr seen;
            report ~narrate ~dst c b ~done_:!seen ~total));
    tally c (fun c -> c.checked <- c.checked + total);
    report ~narrate ~dst c b ~done_:total ~total

  let refuse_open_collection () =
    match Collector.status C.composite with
      | statuses ->
          List.iter
            (fun (s : Collector.status) ->
              match s.record with
                | Record r ->
                    Fail.raise_ Fail.Refused
                      "%s has a collection open in %s, started %s ago: the \
                       chunk area is partly under another name; finish it with \
                       tsync gc, or undo it with tsync gc --abort"
                      s.collected
                      (Gc_record.phase_name r.phase)
                      (Narrate.duration (Unix.gettimeofday () -. r.started))
                | _ -> ())
            statuses

  let manifest_area (src : Store.t) =
    List.filter
      (fun (e : Store.entry) -> Key.leaf e.key <> index_leaf)
      (src.list_prefix (Key.manifests d))

  (* §4.6 Path: markers and manifests down to and under [rel], every chunk
     they name, each checked on the source. *)
  let path_keys (src : Store.t) rel =
    let segs = if rel = "" then [] else String.split_on_char '/' rel in
    let keys = ref [] and chunks = ref [] in
    let add k = keys := k :: !keys in
    let rec descend parent = function
      | [] -> ()
      | seg :: rest -> (
          let slot = Key.child d parent seg in
          match T.find parent [seg] with
            | `Folder id ->
                add slot;
                add (Key.anchor d id);
                descend id rest
            | `File m ->
                add slot;
                chunks := Manifest.keys m @ !chunks
            | `Missing ->
                Fail.raise_ Fail.Absent "%s: no such file or folder in %s" rel
                  (Domain_name.to_string d))
    in
    descend Folder_id.root segs;
    (match T.find Folder_id.root segs with
      | `Folder id ->
          T.fold_tree id ~root_path:rel
            (fun () _ (e : Tree.entry) ->
              add e.key;
              match e.body with
                | Dir m -> add (Key.anchor d m.id)
                | File m -> chunks := Manifest.keys m @ !chunks)
            ()
      | _ -> ());
    let entry k =
      match src.head_opt k with
        | Some e -> e
        | None ->
            Fail.raise_ Fail.Absent "%s is missing from source %s"
              (Key.to_string k) src.name
    in
    let chunks = List.sort_uniq Chunk_key.compare !chunks in
    ( List.map (fun c -> entry (Key.chunk d c)) chunks,
      List.map entry (List.sort_uniq Key.compare !keys) )

  let mirror ?(narrate = Narrate.none) ?(cancelled = Fun.const false) ?source
      scope =
    let members = Composite.members C.composite in
    if List.length members < 2 then
      Fail.raise_ Fail.Invalid "%s has a single member: nothing to mirror to"
        (Domain_name.to_string d);
    let src =
      match source with
        | Some name -> (
            match
              List.find_opt
                (fun (m : Composite.member) -> m.name = name)
                members
            with
              | Some m -> m
              | None ->
                  Fail.raise_ Fail.Invalid "%s has no member named %s"
                    (Domain_name.to_string d) name)
        | None -> List.hd (Composite.in_read_order C.composite)
    in
    (match scope with
      | All | Path _ -> refuse_open_collection ()
      | Manifests -> ());
    let dests =
      List.filter
        (fun (m : Composite.member) ->
          m.name <> src.name && m.role <> Read_only)
        members
    in
    Narrate.say narrate "mirroring %s from %s to %s" (Domain_name.to_string d)
      src.name
      (String.concat ", "
         (List.map (fun (m : Composite.member) -> m.name) dests));
    let path =
      match scope with Path rel -> Some (path_keys src.store rel) | _ -> None
    in
    let copies =
      List.map
        (fun (dst : Composite.member) ->
          Composite.guard C.composite dst "mirror";
          let counts = counts () in
          let run b ~listed =
            if not (cancelled ()) then
              copy_batch ~narrate ~cancelled ~src:src.store ~dst:dst.store
                ~listed counts b
          in
          let listed_batch ?(part = (0, 1)) label prefix ~chunks ~filter =
            run
              {
                label;
                source = List.filter filter (src.store.list_prefix prefix);
                chunks;
                part;
              }
              ~listed:(dst.store.list_prefix prefix)
          in
          let headed label entries ~chunks =
            run
              { label; source = entries; chunks; part = (0, 1) }
              ~listed:
                (List.filter_map
                   (fun (e : Store.entry) -> dst.store.head_opt e.key)
                   entries)
          in
          (match (scope, path) with
            | All, _ ->
                List.iter
                  (fun i ->
                    let shard = Printf.sprintf "%03x" i in
                    listed_batch ~part:(i, 4096) ("chunk shard " ^ shard)
                      (Key.shard_prefix d shard) ~chunks:true ~filter:(fun _ ->
                        true))
                  (List.init 4096 Fun.id);
                run
                  {
                    label = "manifests";
                    source = manifest_area src.store;
                    chunks = false;
                    part = (0, 1);
                  }
                  ~listed:(dst.store.list_prefix (Key.manifests d));
                listed_batch "versions" (Key.versions d) ~chunks:false
                  ~filter:(fun _ -> true);
                listed_batch "journal" (Key.journal d) ~chunks:false
                  ~filter:(fun _ -> true);
                headed "cursor"
                  (Option.to_list (src.store.head_opt (Key.cursor d)))
                  ~chunks:false
            | Manifests, _ ->
                run
                  {
                    label = "manifests";
                    source = manifest_area src.store;
                    chunks = false;
                    part = (0, 1);
                  }
                  ~listed:(dst.store.list_prefix (Key.manifests d))
            | Path _, Some (chunks, keys) ->
                headed "chunks" chunks ~chunks:true;
                headed "manifests" keys ~chunks:false
            | Path _, None -> ());
          let c = counts in
          Narrate.say narrate "  %s: %d checked, %d copied (%s)%s%s" dst.name
            c.checked c.copied (Narrate.size c.bytes)
            (if c.changed > 0 then
               Printf.sprintf ", %d changed since compared" c.changed
             else "")
            (if c.unguarded > 0 then
               Printf.sprintf
                 ", %d written without a precondition (the destination cannot \
                  evaluate one)"
                 c.unguarded
             else "");
          {
            name = dst.name;
            checked = c.checked;
            copied = c.copied;
            copied_bytes = c.bytes;
            changed = c.changed;
            unguarded = c.unguarded;
            failed = List.rev c.failed;
          })
        dests
    in
    { source = src.name; copies; cancelled = cancelled () }
end
