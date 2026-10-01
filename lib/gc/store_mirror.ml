open Tsync_core
open Tsync_store
open Tsync_remote

type scope = All | Manifests | Path of string

type copied = {
  name : string;
  checked : int;
  copied : int;
  copied_bytes : int;
  failed : (string * string) list;
}

type report = { source : string; copies : copied list; cancelled : bool }

let role_order members =
  List.stable_sort
    (fun (a : Composite.member) (b : Composite.member) ->
      compare (Composite.read_rank a.role) (Composite.read_rank b.role))
    members

let index_leaf = ".tsync-index"

module Make (C : Context.S) = struct
  module T = Tree.Make (C)

  let d = C.domain

  (* One batch of keys to compare and copy, listed together; [mutable_] keys
     are compared by body, chunks by size. *)
  type batch = { label : string; source : Store.entry list; mutable_ : bool }

  let copy_batch ~narrate ~cancelled ~(src : Store.t) ~(dst : Store.t) ~listed
      counts b =
    let there = Hashtbl.create 256 in
    List.iter (fun (e : Store.entry) -> Hashtbl.replace there e.key e) listed;
    let checked, copied, bytes, failed = counts in
    let changed =
      List.filter
        (fun (e : Store.entry) ->
          incr checked;
          match Hashtbl.find_opt there e.key with
            | None -> true
            | Some x when x.size <> e.size -> true
            | Some _ when not b.mutable_ -> false
            | Some _ -> (
                match (src.get_opt e.key, dst.get_opt e.key) with
                  | Some a, Some b -> not (Bigstring.equal a b)
                  | Some _, None -> true
                  | None, _ -> false))
        b.source
    in
    let todo = ref changed and m = Mutex.create () in
    let next () =
      Mutex.protect m (fun () ->
          match !todo with
            | e :: rest when not (cancelled ()) ->
                todo := rest;
                Some e
            | _ -> None)
    in
    Rt.each ~width:(max 1 C.max_downloads) next (fun (e : Store.entry) ->
        match src.get_opt e.key with
          | None -> ()
          | Some body -> (
              match dst.put e.key body with
                | () ->
                    Fs.drop_mapped_pages body;
                    Mutex.protect m (fun () ->
                        incr copied;
                        bytes := !bytes + Bigstring.length body)
                | exception ((Stop.Stopping | Rt.Cancelled) as x) -> raise x
                | exception x ->
                    let reason = (Fail.classify x).reason in
                    Narrate.say narrate "  %s refused %s: %s" dst.name
                      (Key.to_string e.key) reason;
                    Mutex.protect m (fun () ->
                        failed := (Key.to_string e.key, reason) :: !failed)));
    Narrate.progress narrate "%s: %s, %d checked, %d copied" dst.name b.label
      !checked !copied

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
        | None -> List.hd (role_order members)
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
          let counts = (ref 0, ref 0, ref 0, ref []) in
          let run b ~listed =
            if not (cancelled ()) then
              copy_batch ~narrate ~cancelled ~src:src.store ~dst:dst.store
                ~listed counts b
          in
          let listed_batch label prefix ~mutable_ ~filter =
            run
              {
                label;
                source = List.filter filter (src.store.list_prefix prefix);
                mutable_;
              }
              ~listed:(dst.store.list_prefix prefix)
          in
          let headed label entries ~mutable_ =
            run
              { label; source = entries; mutable_ }
              ~listed:
                (List.filter_map
                   (fun (e : Store.entry) -> dst.store.head_opt e.key)
                   entries)
          in
          (match (scope, path) with
            | All, _ ->
                List.iter
                  (fun shard ->
                    listed_batch ("chunk shard " ^ shard)
                      (Key.shard_prefix d shard) ~mutable_:false
                      ~filter:(fun _ -> true))
                  (List.init 4096 (Printf.sprintf "%03x"));
                run
                  {
                    label = "manifests";
                    source = manifest_area src.store;
                    mutable_ = true;
                  }
                  ~listed:(dst.store.list_prefix (Key.manifests d));
                listed_batch "versions" (Key.versions d) ~mutable_:true
                  ~filter:(fun _ -> true);
                listed_batch "journal" (Key.journal d) ~mutable_:true
                  ~filter:(fun _ -> true);
                headed "cursor"
                  (Option.to_list (src.store.head_opt (Key.cursor d)))
                  ~mutable_:true
            | Manifests, _ ->
                run
                  {
                    label = "manifests";
                    source = manifest_area src.store;
                    mutable_ = true;
                  }
                  ~listed:(dst.store.list_prefix (Key.manifests d))
            | Path _, Some (chunks, keys) ->
                headed "chunks" chunks ~mutable_:false;
                headed "manifests" keys ~mutable_:true
            | Path _, None -> ());
          let checked, copied, bytes, failed = counts in
          Narrate.say narrate "  %s: %d checked, %d copied (%s)" dst.name
            !checked !copied (Narrate.size !bytes);
          {
            name = dst.name;
            checked = !checked;
            copied = !copied;
            copied_bytes = !bytes;
            failed = List.rev !failed;
          })
        dests
    in
    { source = src.name; copies; cancelled = cancelled () }
end
