open Tsync_core
open Tsync_remote
open Tsync_checkout

let sweep = 60.
let retry_floor = 2.
let feed_line_ops = 64

module Keys = Map.Make (struct
  type t = Algebra.key

  let compare = Algebra.compare_key
end)

(* The cycle of one domain (spec publication §4): arrive, push, project, and
   the recovery of the records they leave. One runs at a time, under
   [cycle_lock]; local operations and uploads run beside it and meet it under
   the metadata lock. *)
module Make (C : Engine_ctx.S) = struct
  include Uploads.Make (C)
  module P = Projection.Make (C)

  let log = Log_store.create d C.store
  let cycle_lock = Rt.Fmutex.create ()
  let paused = Atomic.make false
  let asked = Atomic.make false

  (* Broadcast after every commit and every arrival. *)
  let settled_signal = Rt.Signal.create ()

  type stuck = { n : int; why : [ `Undecodable of string | `Version of int ] }

  let stuck : stuck option Atomic.t = Atomic.make None

  (* The tree head as last read, below 0 until it was. *)
  let tree_head_seen = Atomic.make (-1)

  (* Files whose commit was refused for chunks this client cannot send again
     (publication §4.5): the path, and the content that was refused. Another
     content at the key is pushed like any other. *)
  let damaged : (Algebra.place, string * string) Hashtbl.t = Hashtbl.create 8
  let damaged_m = Mutex.create ()
  let is_damaged p = Mutex.protect damaged_m (fun () -> Hashtbl.mem damaged p)

  let clear_damaged p =
    Mutex.protect damaged_m (fun () -> Hashtbl.remove damaged p)

  let damaged_paths () =
    Mutex.protect damaged_m (fun () ->
        Hashtbl.fold (fun _ (path, _) acc -> path :: acc) damaged [])

  let refused p (m : Manifest.t) =
    Mutex.protect damaged_m (fun () ->
        match Hashtbl.find_opt damaged p with
          | Some (_, identity) -> identity = Log_entry.identity_of m
          | None -> false)

  (* Whether no cycle can commit a pending key as things are: what a caller
     waiting for its commit stops on. *)
  let cannot_commit : Algebra.key -> bool = function
    | `File p -> Atomic.get stuck <> None || is_damaged p
    | `Folder _ -> Atomic.get stuck <> None

  (* The reason the last cycle of the background loop failed, if it did. *)
  let cycle_failing : string option Atomic.t = Atomic.make None
  let null = Algebra.is_null ~equal:same
  let local_file_at p = Option.bind (path_of p) local_file

  let children_of dir parent : Algebra.key list =
    let mirrored =
      List.filter_map
        (fun (c : Mirror.child) ->
          match c.kind with
            | `Dir (Some id) -> Some (`Folder id)
            | `Dir None -> None
            | `File _ -> Some (`File { Algebra.parent; name = c.name }))
        (Mirror.list mirror dir)
    and staged_only =
      List.filter_map
        (fun (p, _) ->
          if Names.parent_of p = dir then
            Some (`File { Algebra.parent; name = Names.leaf_of p })
          else None)
        (Staged.edits_under staged dir)
    in
    List.sort_uniq Algebra.compare_key (mirrored @ staged_only)

  let pending_keys () = List.map Algebra.key_of (Sync_state.pending sync_state)

  (* Whether a key occupies a place of a folder in the local tree. *)
  let in_folder id : Algebra.key -> bool = function
    | `File p -> Folder_id.equal p.parent id && local_file_at p <> None
    | `Folder i -> (
        match local_folder i with
          | Some place -> Folder_id.equal place.parent id
          | None -> false)

  (* [L] (conflict-resolution §3), read under the metadata lock. On a lazy
     tree what a folder holds beyond its pending keys belongs to that folder's
     own view (publication §4.11), so it never keeps a removed folder back. *)
  let l_base : Log_entry.value Algebra.base =
    {
      file = local_file_at;
      folder = local_folder;
      folder_at = (fun p -> Option.bind (path_of p) (Mirror.folder_id mirror));
      children =
        (fun id ->
          if C.lazy_tree then
            List.filter (fun k -> in_folder id k) (pending_keys ())
          else (
            match Mirror.key_of_id mirror id with
              | Some dir -> children_of dir id
              | None -> []));
    }

  (* One command per before-value, from [R] to [L]. *)
  let pending () : Log_entry.command list =
    List.map
      (function
        | `File (p, before, _) -> `File (p, before, l_base.file p)
        | `Folder (i, before, _) -> `Folder (i, before, local_folder i))
      (Sync_state.pending sync_state)

  let aside ~taken ~is_dir name =
    Conflict.free ~client:C.client_name ~is_dir ~taken name

  (* ponytail: a parked folder is a real name of the root for the time of
     one enactment; give the mirror a hidden place if a listing ever shows it. *)
  let park_name id = ".tsync-park-" ^ Folder_id.to_string id

  let resync_generation_path =
    Filename.concat C.data_dir ("resync-" ^ Domain_name.to_string d)

  let watermark_path =
    Filename.concat C.data_dir ("feed-watermark-" ^ Domain_name.to_string d)

  let feed_m = Mutex.create ()

  (* Stamps a new generation and clears the feed watermark (08 §3.6): every
     anchor a frontend holds answers stale. *)
  let stamp_generation () =
    Mutex.protect feed_m (fun () ->
        Fs.durable_replace resync_generation_path
          (Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.));
        if Fs.release watermark_path then Fs.fsync_dir C.data_dir)

  let position () = Sync_state.position sync_state

  (* 04 §2.3: the position of a lazy tree's folder, beside its pull marker. *)
  let folder_position_path dir =
    Filename.concat (Mirror.path mirror dir) ".tsync-position"

  let folder_position dir =
    Option.bind
      (Fs.read_file_opt (folder_position_path dir))
      (fun s -> int_of_string_opt (String.trim s))

  let set_folder_position dir n =
    if Fs.is_dir (Mirror.path mirror dir) then
      Fs.durable_replace (folder_position_path dir) (Key.entry_number n)

  let move_file ~src ~dst =
    let size = size_of src in
    repost_moved (rename_local ~src ~dst ~is_dir:false);
    [
      ( Op.Rename { dst; src; is_dir = false; size = Some size; id = None },
        Mirror.file_id mirror dst );
    ]

  (* An edit staged after an arrival's decision was recorded, which only a
     record completed later can meet: it is kept beside the main's value, with
     the entry it inherits from. *)
  let keep_aside path =
    let dst = aside_name path ~is_dir:false in
    begin_change dst;
    move_file ~src:path ~dst

  (* conflict-resolution §4, one step: idempotent, under the metadata lock and
     the key locks of the files it names. *)
  let apply_step ?(recovered = false) parked :
      Sync_state.step -> (Op.t * string option) list =
    let late path = recovered && Staged.edit staged path <> None in
    function
    | Move (src, dst) -> (
        match (path_of src, path_of dst) with
          | Some s, Some d when kind s = `File && kind d = `Absent ->
              move_file ~src:s ~dst:d
          | _ -> [])
    | File (p, Some m) -> (
        match path_of p with
          | None -> []
          | Some path ->
              let aside = if late path then keep_aside path else [] in
              (match Staged.edit staged path with
                | Some { state = Uploaded mine; _ }
                  when Log_entry.identity_of mine = Log_entry.identity_of m ->
                    (* The same bytes: its bodies become the cache's. *)
                    promote_held path
                | Some _ ->
                    ignore (discard_edit path);
                    cancel_upload path
                | None -> ());
              end_lineage path;
              Mirror.write_file ~durable:false mirror path m;
              let fid = Mirror.ensure_file_id ~durable:false mirror path in
              aside @ [(Op.Put { path; size = m.size }, Some fid)])
    | File (p, None) -> (
        match path_of p with
          | Some path when late path -> keep_aside path
          | Some path when kind path = `File ->
              let fid = Mirror.file_id mirror path in
              ignore (discard_edit path);
              remove_local_file path;
              [(Op.Delete path, fid)]
          | _ -> [])
    | Folder (i, Some place) -> (
        forget_dirs ();
        match path_of place with
          | None -> (
              (* A lazy tree does not hold the folder it moved into. *)
                match Mirror.key_of_id mirror i with
                | Some here when Staged.edits_under staged here = [] ->
                    Mirror.remove_folder mirror here;
                    [(Op.Rmdir { path = here; id = Some i }, None)]
                | _ -> [])
          | Some target -> (
              match Mirror.key_of_id mirror i with
                | Some here when here = target -> []
                | Some here ->
                    repost_moved
                      (rename_local ~src:here ~dst:target ~is_dir:true);
                    if place.name = park_name i then (
                      Hashtbl.replace parked i here;
                      [])
                    else (
                      let src =
                        Option.value ~default:here (Hashtbl.find_opt parked i)
                      in
                      [
                        ( Op.Rename
                            {
                              dst = target;
                              src;
                              is_dir = true;
                              size = None;
                              id = Some i;
                            },
                          None );
                      ])
                | None ->
                    ignore (Mirror.record_folder ~durable:false mirror target i);
                    [(Op.Mkdir { path = target; id = Some i }, None)]))
    | Folder (i, None) -> (
        forget_dirs ();
        match Mirror.key_of_id mirror i with
          | Some here ->
              Mirror.remove_folder mirror here;
              [(Op.Rmdir { path = here; id = Some i }, None)]
          | None -> [])

  let rec lines = function
    | [] -> []
    | ops ->
        let line = List.filteri (fun i _ -> i < feed_line_ops) ops
        and rest = List.filteri (fun i _ -> i >= feed_line_ops) ops in
        line :: lines rest

  (* publication §4.4 and §4.8 step 2: every part idempotent. A record that
     recovery completes cannot tell which of its feed lines it had appended,
     so it invalidates the feed's anchors instead. *)
  let run_arrival ?(recovered = false) (a : Sync_state.arrival) =
    let parked = Hashtbl.create 2 in
    let ops = List.concat_map (apply_step ~recovered parked) a.steps in
    if a.steps <> [] then Fs.syncfs (Mirror.root mirror);
    (* 04 §4.7: before its before-value goes, and under the record. *)
    List.iter
      (function
        | `File p, Sync_state.Drop ->
            Option.iter
              (fun path ->
                match Staged.edit staged path with
                  | Some { state = Uploaded _; _ } -> promote_held path
                  | _ -> ())
              (path_of p)
        | _ -> ())
      a.before;
    List.iter
      (fun ((key : Algebra.key), (settled : Sync_state.settled)) ->
        match (key, settled) with
          | _, Drop -> Sync_state.drop sync_state key
          | `File p, Before_file v ->
              if Sync_state.before_file sync_state p <> Some v then
                Sync_state.set_file sync_state p v
          | `Folder i, Before_folder v ->
              if Sync_state.before_folder sync_state i <> Some v then
                Sync_state.set_folder sync_state i v
          | _ -> ())
      a.before;
    (match a.view with
      | None -> Sync_state.set_position sync_state a.head
      | Some id ->
          Option.iter
            (fun dir -> set_folder_position dir a.head)
            (Mirror.key_of_id mirror id));
    if recovered then stamp_generation ()
    else
      List.iter
        (fun line ->
          let fids =
            List.concat
              (List.mapi
                 (fun i (_, fid) ->
                   match fid with Some f -> [(i, f)] | None -> [])
                 line)
          in
          feed ~fids (List.map fst line))
        (lines ops);
    Sync_state.clear_arrival sync_state;
    List.concat_map (fun (op, _) -> Op.paths op) ops

  let removals_last : Log_entry.command list -> Log_entry.command list =
    List.stable_sort (fun a b ->
        let rank : Log_entry.command -> int = function
          | `File (_, _, None) | `Folder (_, _, None) -> 1
          | _ -> 0
        in
        compare (rank a) (rank b))

  (* The steps that take [L] to [N]: files moved aside first, to names free in
     both, then the rest in an order Theorem 3 allows. *)
  let steps_of (merged : Log_entry.value Algebra.merged) : Sync_state.step list
      =
    let targets = List.map snd merged.asides in
    let rest =
      List.filter
        (function `File (p, _, _) -> not (List.mem p targets) | _ -> true)
        merged.local
    in
    let moved =
      Algebra.apply (Algebra.of_base l_base)
        (List.concat_map
           (fun (src, dst) ->
             [`File (src, None, None); `File (dst, None, l_base.file src)])
           merged.asides)
    in
    let ordered =
      List.mapi
        (fun i step -> (i, step))
        (Algebra.order ~temp:park_name moved (removals_last rest))
    in
    (* conflict-resolution §4.1, a move the main made: a removal of an
       unedited file paired with an earlier creation of the same content. *)
    let unedited p =
      match path_of p with
        | Some path -> Staged.edit staged path = None
        | None -> false
    in
    let removed =
      List.filter_map
        (function
          | i, `Set (`File (p, Some (Log_entry.Known m), None)) when unedited p
            ->
              Some (i, p, Log_entry.identity_of m)
          | _ -> None)
        ordered
    in
    let moves, _ =
      List.fold_left
        (fun (moves, used) -> function
          | j, `Set (`File (dst, None, Some (Log_entry.Known m))) -> (
              match
                List.find_opt
                  (fun (i, src, identity) ->
                    i > j
                    && identity = Log_entry.identity_of m
                    && not (List.mem src used))
                  removed
              with
                | Some (_, src, _) -> ((j, src, dst) :: moves, src :: used)
                | None -> (moves, used))
          | _ -> (moves, used))
        ([], []) ordered
    in
    List.map (fun (src, dst) -> Sync_state.Move (src, dst)) merged.asides
    @ List.filter_map
        (fun (j, step) ->
          match (List.find_opt (fun (at, _, _) -> at = j) moves, step) with
            | Some (_, src, dst), _ -> Some (Sync_state.Move (src, dst))
            | None, `Set (`File (p, _, None)) ->
                if List.exists (fun (_, src, _) -> src = p) moves then None
                else Some (Sync_state.File (p, None))
            | None, `Set (`File (p, _, Some (Log_entry.Known m))) ->
                Some (File (p, Some m))
            | None, `Set (`File ((p : Algebra.place), _, Some _)) ->
                Fail.corrupt "%s: a merge installs a value that is no manifest"
                  p.name
            | None, `Set (`Folder (i, _, place)) -> Some (Folder (i, place))
            | None, `Park (i, _, place) -> Some (Folder (i, Some place)))
        ordered

  (* publication §4.4, "Only the keys fetched": a key the entries do not name
     and the merge leaves as it is keeps its before-value, which a local
     operation in progress may have just recorded. *)
  let settled_of ~(theirs : Log_entry.command list)
      (merged : Log_entry.value Algebra.merged) =
    let keys = List.map Algebra.key_of (theirs @ merged.local) in
    List.filter_map
      (fun (c : Log_entry.command) ->
        let key = Algebra.key_of c in
        if not (List.mem key keys) then None
        else
          Some
            ( key,
              if null c then Sync_state.Drop
              else (
                match c with
                  | `File (_, m, _) -> Before_file m
                  | `Folder (_, m, _) -> Before_folder m) ))
      merged.pending

  (* Every local path whose key lock an enactment needs: the file keys it
     changes or settles and the staged keys under the folders it moves. *)
  let paths_of (a : Sync_state.arrival) =
    List.sort_uniq String.compare
      (List.concat_map
         (fun (step : Sync_state.step) ->
           match step with
             | Move (src, dst) -> List.filter_map path_of [src; dst]
             | File (p, _) -> Option.to_list (path_of p)
             | Folder (i, _) -> (
                 match Mirror.key_of_id mirror i with
                   | Some dir -> List.map fst (Staged.edits_under staged dir)
                   | None -> []))
         a.steps
      @ List.concat_map
          (function `File p, _ -> Option.to_list (path_of p) | _ -> [])
          a.before)

  let describe_clash (merged : Log_entry.value Algebra.merged) =
    let key : Algebra.key -> string = function
      | `File p -> Folder_id.to_string p.parent ^ "/" ^ p.name
      | `Folder i -> Folder_id.to_string i
    in
    if merged.asides <> [] || merged.restored <> [] then
      Log.info "%s: merge clashed on %s; %d kept aside, %d folders restored"
        (Domain_name.to_string d)
        (String.concat ", "
           (List.filter_map
              (fun c -> if null c then None else Some (key (Algebra.key_of c)))
              merged.pending))
        (List.length merged.asides)
        (List.length merged.restored)

  (* Whether a command is on a key of a folder's view (publication §4.11): a
     file key under it, or a folder key whose place is or was in it. *)
  let concerns id : Log_entry.command -> bool =
    let inside = function
      | Some (place : Algebra.place) -> Folder_id.equal place.parent id
      | None -> false
    in
    function
    | `File (p, _, _) -> Folder_id.equal p.parent id
    | `Folder (_, before, after) -> inside before || inside after

  (* publication §4.4 from the merge on. The decision is taken again with the
     key locks held, since a write may stage an edit under its key lock alone
     (conflict-resolution §4.1). *)
  let merge_and_enact ?view ~head (theirs : Log_entry.command list) =
    let before () =
      match view with
        | None -> pending ()
        | Some id -> List.filter (concerns id) (pending ())
    in
    let decide () =
      Algebra.merge ~equal:same ~aside ~l:l_base ~before:(before ()) ~theirs ()
    in
    (* conflict-resolution §4.1, the same change on both sides: the key is
       left as it is by the merge, and the main's manifest is the one every
       client ends with (change-algebra §7.3). *)
    let same_change (merged : Log_entry.value Algebra.merged) =
      List.filter_map
        (function
          | `File (p, _, Some (Log_entry.Known m))
            when not
                   (List.exists
                      (fun c -> Algebra.key_of c = `File p)
                      merged.local) -> (
              match l_base.file p with
                | Some (Known mine)
                  when Log_entry.identity_of mine = Log_entry.identity_of m
                       && mine <> m ->
                    Some (Sync_state.File (p, Some m))
                | _ -> None)
          | _ -> None)
        theirs
    in
    let arrival_of merged =
      {
        Sync_state.head;
        view;
        steps = steps_of merged @ same_change merged;
        before = settled_of ~theirs merged;
      }
    in
    let rec attempt paths rounds =
      let outcome =
        with_keys paths (fun () ->
            let merged = decide () in
            let arrival = arrival_of merged in
            let need = paths_of arrival in
            let held = Hashtbl.create (List.length paths) in
            List.iter (fun p -> Hashtbl.replace held p ()) paths;
            if List.for_all (Hashtbl.mem held) need then (
              describe_clash merged;
              Sync_state.set_arrival sync_state arrival;
              `Done (run_arrival arrival))
            else `Again need)
      in
      match outcome with
        | `Done changed -> changed
        | `Again _ when rounds = 0 ->
            Fail.raise_ Fail.Link
              "the local tree kept changing under an arrival"
        | `Again need -> attempt need (rounds - 1)
    in
    let touched =
      with_meta (fun () ->
          keeping_dirs (fun () -> attempt (paths_of (arrival_of (decide ()))) 8))
    in
    Rt.Signal.broadcast settled_signal;
    changed touched;
    List.length touched

  let theirs_of = Log_store.last_commands

  (* publication §4.3. *)
  let fetch h =
    let rec go n acc =
      match Log_store.read_entries log n with
        | _ :: _ as more -> go (n + List.length more) (acc @ more)
        | [] ->
            let t = Log_store.tree_head log in
            Atomic.set tree_head_seen t;
            if t < n then `Entries acc
            else if Log_store.read_entry log n <> None then go n acc
            else `Pruned
    in
    go (h + 1) []

  let unfollowable (e : Log_store.entry) =
    match e.read with
      | Undecodable why -> Some { n = e.n; why = `Undecodable why }
      | Later_version v -> Some { n = e.n; why = `Version v }
      | Entry _ | Void -> None

  (* Every key of the local tree: one walk of the mirror, and the staged edits
     read once. *)
  let local_keys () : Algebra.key list =
    let rec walk dir parent acc =
      List.fold_left
        (fun acc (c : Mirror.child) ->
          match c.kind with
            | `File _ -> `File { Algebra.parent; name = c.name } :: acc
            | `Dir (Some id) ->
                walk (Names.join dir c.name) id (`Folder id :: acc)
            | `Dir None -> acc)
        acc (Mirror.list mirror dir)
    in
    walk "" Folder_id.root []
    @ List.filter_map
        (fun (path, _) -> Option.map (fun p -> `File p) (place_opt path))
        (Staged.edits staged)

  (* What a state read gives: the head it reached, the commands from [R] to
     [M], and the files and folders counted. *)
  type state = {
    head : int;
    theirs : Log_entry.command list;
    read : [ `Entries of int | `State of int * int ];
  }

  (* publication §4.7: the tree as its records say, then every entry above
     the tree head replayed over it. Only the keys where [M] differs from [R]
     are kept, with every key of [R] that the main lacks. *)
  let rec state_read ?(narrate = Narrate.none) () : state =
    let t = Log_store.tree_head log in
    let seen = Hashtbl.create 4096 in
    let dirs = Hashtbl.create 256 in
    let dir_of id =
      match Hashtbl.find_opt dirs id with
        | Some dir -> dir
        | None ->
            let dir = Mirror.key_of_id mirror id in
            Hashtbl.replace dirs id dir;
            dir
    in
    let r_file (p : Algebra.place) =
      match Sync_state.before_file sync_state p with
        | Some before -> before
        | None ->
            Option.bind (dir_of p.parent) (fun dir ->
                local_file (Names.join dir p.name))
    and r_folder i =
      match Sync_state.before_folder sync_state i with
        | Some before -> before
        | None -> local_folder i
    in
    let folders = Hashtbl.create 1024 and files = ref 0 in
    let walked =
      P.fold
        (fun acc record ->
          match record with
            | `File (p, m) ->
                incr files;
                Narrate.progress narrate "reading the main's tree: %s"
                  (Narrate.count !files "file");
                Hashtbl.replace seen (`File p) ();
                let v = Some (Log_entry.Known m) in
                if same_file (r_file p) v then acc
                else `File (p, None, v) :: acc
            | `Folder (i, place) ->
                Hashtbl.replace seen (`Folder i) ();
                Hashtbl.replace folders i place;
                if r_folder i = Some place then acc
                else `Folder (i, None, Some place) :: acc)
        []
    in
    match fetch t with
      | `Pruned -> state_read ~narrate ()
      | `Entries entries -> (
          match List.find_map unfollowable entries with
            | Some s ->
                Atomic.set stuck (Some s);
                Fail.raise_ Fail.Corrupt
                  "log entry %d cannot be followed and the tree head has not \
                   passed it"
                  s.n
            | None ->
                let gone () =
                  List.filter_map
                    (fun (k : Algebra.key) ->
                      if Hashtbl.mem seen k then None
                      else (
                        Hashtbl.replace seen k ();
                        match k with
                          | `File p -> Some (`File (p, None, None))
                          | `Folder i -> Some (`Folder (i, None, None))))
                    (local_keys ()
                    @ List.map Algebra.key_of (Sync_state.pending sync_state))
                in
                let replayed = theirs_of entries in
                List.iter
                  (function
                    | `Folder (i, _, Some place) ->
                        Hashtbl.replace folders i place
                    | `Folder (i, _, None) -> Hashtbl.remove folders i
                    | `File _ -> ())
                  replayed;
                (* 05 §4.7 step 6: what the records hold that is no part of a
                   tree, a folder from which the root is not reached and a
                   file in a folder the tree lacks, is left out. *)
                let rec rooted seen i =
                  Folder_id.is_root i
                  || (not (List.exists (Folder_id.equal i) seen))
                     &&
                       match Hashtbl.find_opt folders i with
                       | Some (place : Algebra.place) ->
                           rooted (i :: seen) place.parent
                       | None -> false
                in
                let unrooted =
                  Hashtbl.fold
                    (fun i _ acc -> if rooted [] i then acc else i :: acc)
                    folders []
                in
                List.iter
                  (fun i ->
                    Log.warn "state read: folder %s is not part of the tree"
                      (Folder_id.to_string i);
                    Hashtbl.remove folders i)
                  unrooted;
                let orphans =
                  List.map (fun i -> `Folder (i, None, None)) unrooted
                  @ Hashtbl.fold
                      (fun (k : Algebra.key) () acc ->
                        match k with
                          | `File p
                            when (not (Folder_id.is_root p.parent))
                                 && not (Hashtbl.mem folders p.parent) ->
                              Log.warn
                                "state read: %s/%s is in a folder the tree \
                                 lacks"
                                (Folder_id.to_string p.parent)
                                p.name;
                              `File (p, None, None) :: acc
                          | _ -> acc)
                      seen []
                in
                let all =
                  List.fold_left
                    (fun acc c -> Keys.add (Algebra.key_of c) c acc)
                    Keys.empty
                    (gone () @ walked @ replayed @ orphans)
                in
                {
                  head = t + List.length entries;
                  theirs = List.map snd (Keys.bindings all);
                  read = `State (!files, Hashtbl.length folders);
                })

  (* publication §4.7. Once its entry is gone the in-flight record cannot say
     whether the batch was committed, so the merge decides key by key. *)
  let arrive_by_state ?narrate () =
    let { head; theirs; read } = state_read ?narrate () in
    Sync_state.clear_in_flight sync_state;
    let changed = merge_and_enact ~head theirs in
    Sync_state.state_read sync_state;
    (read, changed)

  (* The folders whose views a batch was committed from (publication §4.11):
     those holding a key of it, and their ancestors up to the root. *)
  let views_of (batch : Log_entry.command list) =
    let rec up acc id =
      if List.exists (Folder_id.equal id) acc then acc
      else (
        let acc = id :: acc in
        match local_folder id with
          | Some place -> up acc place.parent
          | None -> acc)
    in
    let parent = function
      | Some (place : Algebra.place) -> [place.parent]
      | None -> []
    in
    List.fold_left up []
      (List.concat_map
         (function
           | `File ((p : Algebra.place), _, _) -> [p.parent]
           | `Folder (_, before, after) -> parent before @ parent after)
         batch)

  let commit_position n batch =
    if C.lazy_tree then
      List.iter
        (fun id ->
          Option.iter
            (fun dir -> set_folder_position dir n)
            (Mirror.key_of_id mirror id))
        (views_of batch)
    else Sync_state.set_position sync_state n

  (* The [Won] step (publication §4.5): the staged edits it committed are
     promoted, then the before-values, the position and the in-flight
     record. *)
  let won n (batch : Log_entry.command list) =
    let paths =
      List.sort_uniq String.compare
        (List.concat_map
           (function
             | `File (p, _, _) -> Option.to_list (path_of p) | `Folder _ -> [])
           batch)
    in
    with_meta (fun () ->
        with_keys paths (fun () ->
            List.iter
              (function
                | `File (p, _, after) when same_file (l_base.file p) after ->
                    Option.iter promote_held (path_of p)
                | _ -> ())
              batch;
            List.iter
              (function
                | `File (p, _, after) ->
                    clear_damaged p;
                    if same_file (l_base.file p) after then
                      Sync_state.drop sync_state (`File p)
                    else Sync_state.set_file sync_state p after
                | `Folder (i, _, after) ->
                    if local_folder i = after then
                      Sync_state.drop sync_state (`Folder i)
                    else Sync_state.set_folder sync_state i after)
              batch;
            commit_position n batch;
            Sync_state.clear_in_flight sync_state));
    Log_store.cursor_note log n;
    Rt.Signal.broadcast settled_signal

  let missing_of = function
    | Fail.E { kind = Missing_chunks names; _ } ->
        Some (List.filter_map Chunk_key.of_string names)
    | _ -> None

  (* The bytes of chunk [i] of [m] where this client holds them without
     asking the main: a staged body, or a whole group of its cache. *)
  let held path (m : Manifest.t) i =
    let cc = Cache.cc cache in
    let cached (m : Manifest.t) i =
      let g = Cache.group_of ~cc m (Cache.group_index ~cc m i) in
      if not (Cache.is_whole cache g.gkey) then None
      else
        Option.map
          (Cache.verified_member cache g)
          (List.find_opt (fun (x : Cache.member) -> x.index = i) g.members)
    in
    let bytes =
      match Staged.edit staged path with
        | Some ({ content = Whole _; _ } as e) -> Some (`Staged e)
        | Some ({ content = Slots slots; _ } as e)
          when i < Array.length slots && slots.(i) <> Staged.Inherit ->
            Some (`Staged e)
        | Some _ -> (
            match cached m i with
              | Some b -> Some (`Bytes b)
              | None ->
                  Option.bind (Mirror.manifest mirror path) (fun base ->
                      if i < base.count then
                        Option.map (fun b -> `Bytes b) (cached base i)
                      else None))
        | None -> Option.map (fun b -> `Bytes b) (cached m i)
    in
    let bytes =
      match bytes with
        | Some (`Bytes b) -> Some b
        | Some (`Staged e) ->
            Some
              (read_staged path e ~off:(i * m.chunk_size)
                 ~len:(Chunking.length ~size:m.size ~cs:m.chunk_size i))
        | None -> None
    in
    match bytes with
      | Some b
        when Chunk_key.equal (Chunk_key.of_bigstring b) (Manifest.key m i) ->
          Some b
      | _ -> None

  (* publication §4.5, missing chunks: each is sent again from the bytes this
     client holds, its staged bodies or its cache; a file with a chunk it
     holds nowhere is left out and reported. *)
  let chunks_refused (batch : Log_entry.command list) missing =
    R.drop_memo missing;
    let lacks ck = List.exists (Chunk_key.equal ck) missing in
    List.iter
      (function
        | `File (p, _, Some (Log_entry.Known m))
          when List.exists lacks (Manifest.keys m) -> (
            match path_of p with
              | None -> ()
              | Some path ->
                  with_key path (fun () ->
                      (* A value the key no longer holds is no longer pushed. *)
                      if same_file (l_base.file p) (Some (Known m)) then (
                        let sent i =
                          let ck = Manifest.key m i in
                          (not (lacks ck))
                          ||
                            match
                              try held path m i with
                                | (Stop.Stopping | Rt.Cancelled) as e -> raise e
                                | _ -> None
                            with
                            | Some b ->
                                R.put_chunk ck b;
                                true
                            | None -> false
                        in
                        if not (List.for_all sent (List.init m.count Fun.id))
                        then (
                          Log.warn
                            "%s: the main lacks its content and this client \
                             has no bytes to send again"
                            path;
                          Mutex.protect damaged_m (fun () ->
                              Hashtbl.replace damaged p
                                (path, Log_entry.identity_of m))))))
        | _ -> ())
      batch

  let commit n body batch =
    match Log_store.create_entry log n body with
      | `Won ->
          won n batch;
          `Committed n
      | `Held -> `Refused
      | exception e -> (
          match missing_of e with
            | Some missing ->
                Sync_state.clear_in_flight sync_state;
                chunks_refused batch missing;
                `Refused
            | None -> raise e)

  let batch_of_body body =
    match Log_entry.decode body with
      | `Entry e -> e.commands
      | `Later_version _ | `Corrupt _ ->
          Fail.corrupt "the in-flight record does not hold an entry"

  (* publication §4.8, RECOVER. *)
  let recover_in_flight () =
    match Sync_state.in_flight sync_state with
      | None -> ()
      | Some { n; body } -> (
          match Log_store.read_entry log n with
            | Some e when e.bytes = body ->
                (* The claim's answer never came, so nothing queued the entry
                   for the copies. *)
                Tsync_store.Composite.owe C.composite (Key.log_entry d n);
                won n (batch_of_body body)
            | Some _ -> Sync_state.clear_in_flight sync_state
            | None when Log_store.tree_head log >= n ->
                if C.lazy_tree then Sync_state.clear_in_flight sync_state
                else ignore (arrive_by_state ())
            | None -> ignore (commit n body (batch_of_body body)))

  (* The record is read under the metadata lock: one seen without it may be
     that of an enactment still running, a host's pull on a lazy tree, which
     clears it before it lets the lock go. *)
  let complete_arrival () =
    if Sync_state.arrival sync_state <> None then
      changed
        (with_meta (fun () ->
             match Sync_state.arrival sync_state with
               | None -> []
               | Some a ->
                   with_keys (paths_of a) (fun () ->
                       run_arrival ~recovered:true a)))

  (* publication §4.4: what was merged, and how many paths it changed. *)
  let arrive ?narrate ?(full = false) () =
    complete_arrival ();
    recover_in_flight ();
    match position () with
      | None -> arrive_by_state ?narrate ()
      | Some _ when full || Sync_state.needs_state sync_state ->
          arrive_by_state ?narrate ()
      | Some h -> (
          match fetch h with
            | `Pruned -> arrive_by_state ?narrate ()
            | `Entries [] ->
                Atomic.set stuck None;
                (`Entries 0, 0)
            | `Entries entries -> (
                match List.find_map unfollowable entries with
                  | Some s when Atomic.get tree_head_seen >= s.n ->
                      arrive_by_state ?narrate ()
                  | Some s ->
                      Atomic.set stuck (Some s);
                      Fail.raise_ Fail.Corrupt
                        "log entry %d cannot be followed: fetching and pushing \
                         stop until it is voided or this client is upgraded"
                        s.n
                  | None ->
                      Atomic.set stuck None;
                      ( `Entries (List.length entries),
                        merge_and_enact
                          ~head:(h + List.length entries)
                          (theirs_of entries) )))

  (* The commands a pull of one folder merges (publication §4.11): the last
     value the entries give every key that any of them touched in the folder,
     so a key that left the view and changed again is still seen leaving. *)
  let view_commands id (entries : Log_store.entry list) =
    let touched = Hashtbl.create 16 in
    List.iter
      (fun e ->
        List.iter
          (fun c ->
            if concerns id c then Hashtbl.replace touched (Algebra.key_of c) ())
          (Option.value ~default:[] (Log_store.commands e)))
      entries;
    List.filter
      (fun c -> Hashtbl.mem touched (Algebra.key_of c))
      (theirs_of entries)

  let pulled_marker dir =
    Filename.concat (Mirror.path mirror dir) ".tsync-pulled"

  (* publication §4.11, a pull: an arrival for one folder, by the entries
     after its position, or by state when it has none or they are pruned;
     whether it changed the local tree. *)
  let pull_folder dir =
    let id =
      match Mirror.folder_id mirror dir with
        | Some id -> id
        | None ->
            Fail.raise_ Fail.Unprepared "%s: this client has not resolved it"
              dir
    in
    let by_state () =
      let t = Log_store.tree_head log in
      let records =
        T.children
          ~on_unusable:
            (Tree.Skip
               (fun u -> Log.debug "pull: %s" (Tree.describe_unusable u)))
          id
      in
      match fetch t with
        | `Pruned ->
            Fail.raise_ Fail.Link "the log moved under a pull of %s" dir
        | `Entries entries ->
            let walked : Log_entry.command list =
              List.map
                (fun (e : Tree.entry) ->
                  match e.body with
                    | File m ->
                        `File
                          ( { Algebra.parent = id; name = m.name },
                            None,
                            Some (Log_entry.Known m) )
                    | Dir m ->
                        `Folder
                          ( m.id,
                            None,
                            Some { Algebra.parent = id; name = m.name } ))
                records
            in
            let held =
              with_meta (fun () ->
                  children_of dir id
                  @ List.filter_map
                      (fun c ->
                        if concerns id c then Some (Algebra.key_of c) else None)
                      (pending ()))
            in
            let gone =
              List.map
                (function
                  | `File p -> `File (p, None, None)
                  | `Folder i -> `Folder (i, None, None))
                held
            in
            let all =
              List.fold_left
                (fun acc c -> Keys.add (Algebra.key_of c) c acc)
                Keys.empty
                (gone @ walked @ view_commands id entries)
            in
            (t + List.length entries, List.map snd (Keys.bindings all))
    in
    let head, theirs =
      match folder_position dir with
        | None -> by_state ()
        | Some h -> (
            match fetch h with
              | `Pruned -> by_state ()
              | `Entries entries ->
                  (h + List.length entries, view_commands id entries))
    in
    (* A folder moved into one this client does not hold leaves the view. *)
    let theirs =
      List.map
        (function
          | `Folder (i, before, Some (place : Algebra.place))
            when (not (Folder_id.equal place.parent id))
                 && (not (Folder_id.is_root place.parent))
                 && Mirror.key_of_id mirror place.parent = None ->
              `Folder (i, before, None)
          | c -> c)
        theirs
    in
    let changed =
      if theirs = [] && folder_position dir = Some head then 0
      else merge_and_enact ~view:id ~head theirs
    in
    Fs.replace (pulled_marker dir)
      (Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.));
    changed > 0

  (* publication §4.5, "which batch": the pushable commands, without the
     removals an Owed edit still inherits from, as many as an entry holds; and
     no removal of content that a command left out creates elsewhere. *)
  (* publication §4.5: the entry this client creates of a batch. *)
  let entry_of batch : Log_entry.t =
    { author = C.client_uuid; projector = projector (); commands = batch }

  let choose_batch () : Log_entry.command list =
    let all = List.filter (fun c -> not (null c)) (pending ()) in
    let created : Log_entry.command -> string option = function
      | `File (_, _, Some v) -> Log_entry.identity v
      | _ -> None
    and removed : Log_entry.command -> string option = function
      | `File (_, Some before, _) -> Log_entry.identity before
      | _ -> None
    in
    let inherited =
      List.filter_map
        (fun (path, (e : Staged.edit)) ->
          if e.state = Owed then
            Option.map Log_entry.identity_of (Mirror.manifest mirror path)
          else None)
        (Staged.edits staged)
    in
    let pushable : Log_entry.command -> bool = function
      | `File (p, _, Some (Known m)) -> not (refused p m)
      | `File (_, _, Some (Identity _ | Unknown)) -> false
      | `File (_, _, None) | `Folder _ -> true
    in
    let held_back c =
      match removed c with Some x -> List.mem x inherited | None -> false
    in
    let r =
      Algebra.apply (Algebra.of_base l_base)
        (List.map
           (function
             | `File (p, before, _) -> `File (p, None, before)
             | `Folder (i, before, _) -> `Folder (i, None, before))
           all)
    in
    let fits batch =
      List.length batch <= 1
      || String.length (Log_entry.encode (entry_of batch))
         <= (tuning ()).max_entry_bytes
    in
    let rec choose candidates limit =
      let steps, _ = Algebra.take ?limit ~temp:park_name r candidates in
      let batch =
        List.filter_map (function `Set c -> Some c | `Park _ -> None) steps
      in
      let left = List.filter (fun c -> not (List.memq c batch)) all in
      let elsewhere = List.filter_map created left in
      let early =
        List.filter
          (fun c ->
            match removed c with
              | Some x -> created c <> Some x && List.mem x elsewhere
              | None -> false)
          batch
      in
      if early <> [] then
        choose (List.filter (fun c -> not (List.memq c early)) candidates) limit
      else if batch = [] && candidates <> [] && limit <> None then
        choose candidates None
      else if not (fits batch) then (
        (* publication §4.5, splitting: commands that only commit together
           share an entry, whatever its size. *)
          match choose candidates (Some (List.length batch / 2)) with
          | [] -> batch
          | smaller -> smaller)
      else batch
    in
    choose
      (removals_last
         (List.filter (fun c -> pushable c && not (held_back c)) all))
      (Some (tuning ()).max_entry_commands)

  (* The position a push is made from. On a lazy tree every folder that holds
     a pending key, and every ancestor, is pulled first, and all must stand at
     one head (publication §4.11). *)
  let push_position () =
    if not C.lazy_tree then position ()
    else (
      let views =
        List.filter_map (Mirror.key_of_id mirror)
          (with_meta (fun () -> views_of (pending ())))
      in
      List.iter (fun dir -> ignore (pull_folder dir)) views;
      match List.sort_uniq compare (List.map folder_position views) with
        | [Some h] -> Some h
        | [] -> None
        | _ ->
            Fail.raise_ Fail.Link "the head moved between the pulls of a push")

  (* publication §4.5. *)
  let push () =
    match push_position () with
      | None -> `Nothing
      | Some h -> (
          let chosen =
            with_meta (fun () ->
                match choose_batch () with
                  | [] -> None
                  | batch ->
                      let body = Log_entry.encode (entry_of batch) in
                      Sync_state.set_in_flight sync_state { n = h + 1; body };
                      Some (body, batch))
          in
          match chosen with
            | None -> `Nothing
            | Some (body, batch) -> commit (h + 1) body batch)

  (* What this owner saw of the entry after the tree head: the generation it
     watches, or the takeover it holds, and since when. *)
  type watch = { entry : int; generation : int; since : float }

  let watching : watch option ref = ref None
  let took : watch option ref = ref None

  (* publication §4.6: one entry, and whether it was projected. The settle
     and the quarantine are waited out across cycles, never inside one. *)
  let project () =
    let apply ~t ~generation (e : Log_store.entry) commands =
      let checked = ref neg_infinity and taken_over = ref false in
      (* The fibers writing one pass share the check: one makes it, the others
         wait for its answer, a failure included. *)
      let checking = Rt.Fmutex.create () in
      let before_write () =
        Rt.Fmutex.with_lock checking (fun () ->
            if
              (not !taken_over)
              && Rt.boottime () -. !checked >= (tuning ()).project_lease /. 2.
            then (
              let now = Rt.boottime () in
              taken_over :=
                Log_store.tree_head log <> t
                || fst (Log_store.takeover log e.n) <> generation;
              checked := now);
            if !taken_over then
              Fail.raise_ Fail.Link "the projection of entry %d was taken over"
                e.n)
      in
      P.apply ~width:(tuning ()).project_width ~before_write commands;
      before_write ();
      Log_store.raise_tree_head log e.n;
      Atomic.set tree_head_seen e.n
    in
    let held (w : watch option) (e : Log_store.entry) generation =
      match w with
        | Some w when w.entry = e.n && w.generation = generation -> Some w.since
        | _ -> None
    in
    let projected = ref false in
    (* §4.6: behind a main that states a projector this client commits and
       nothing more; the serving owner is the one projector there. *)
    let served =
      match projector () with Some p -> p <> C.client_uuid | None -> false
    in
    let one () =
      let t = Log_store.tree_head log in
      Atomic.set tree_head_seen t;
      (* A read-only client writes nothing to the main (§4.6, "Who"). *)
      if not (served || C.read_only) then (
        match Log_store.read_entry log (t + 1) with
          | None -> ()
          | Some e -> (
              let generation, holder = Log_store.takeover log e.n in
              let now = Rt.boottime () in
              let mine =
                (* §4.6: one projector for a domain its listener projects. *)
                C.projects_all
                ||
                  match (holder, e.read) with
                  | Some client, _ -> client = C.client_uuid
                  | None, Entry { author; projector; _ } ->
                      Option.value ~default:author projector = C.client_uuid
                  | None, _ -> false
              in
              match (mine, Log_store.commands e) with
                | true, Some commands when generation = 0 ->
                    apply ~t ~generation e commands;
                    projected := true
                | true, Some commands -> (
                    match held !took e generation with
                      | Some since
                        when now -. since >= (tuning ()).project_quarantine ->
                          apply ~t ~generation e commands;
                          projected := true
                      | Some _ -> ()
                      | None ->
                          took := Some { entry = e.n; generation; since = now })
                | true, None -> ()
                | false, _ -> (
                    match held !watching e generation with
                      | Some since ->
                          if
                            now -. since >= (tuning ()).project_settle
                            && Log_store.takeover_create log e.n
                                 ~generation:(generation + 1)
                                 ~client:C.client_uuid
                               = `Won
                          then
                            (* The quarantine runs from the takeover's creation,
                               not from before its request. *)
                            took :=
                              Some
                                {
                                  entry = e.n;
                                  generation = generation + 1;
                                  since = Rt.boottime ();
                                }
                      | None ->
                          watching :=
                            Some { entry = e.n; generation; since = now })))
    in
    one ();
    !projected

  type cycled = {
    arrival : [ `Entries of int | `State of int * int ];
    changed : int;
    committed : int;
  }

  (* One cycle (publication §4): arrive, push one entry when [push_now], which
     is false while the batch delay runs, and project one. A lazy tree arrives
     folder by folder when its host pulls, so its cycle only recovers, pushes
     and projects. *)
  let step ?narrate ?(full = false) ~push_now () =
    Rt.Fmutex.with_lock cycle_lock (fun () ->
        if C.lazy_tree then complete_arrival ();
        (* 05 §2.1: nothing is pushed or projected before the main was asked
           for its settings, the projector it states among them. *)
        ignore (R.stated ~wait:true ());
        (* §4.6, "When": the one projector of a domain projects before its
           arrival, so that a merge that fails or takes long here holds up no
           client it serves; its failure waits for the arrival and the push.
           Any other client projects after both. *)
        let first =
          if not C.projects_all then `Projected false
          else (
            try `Projected (project ()) with
              | (Stop.Stopping | Rt.Cancelled) as e -> raise e
              | e -> `Failed e)
        in
        let arrival, changed =
          if C.lazy_tree then (
            recover_in_flight ();
            (`Entries 0, 0))
          else arrive ?narrate ~full ()
        in
        let pushed = if push_now then push () else `Nothing in
        let projected =
          match first with
            | `Failed e -> raise e
            | `Projected first -> first || project ()
        in
        (arrival, changed, pushed, projected))

  (* 07 §2.6: paused, the one projector of a domain goes on projecting, and
     any other client projects nothing and takes nothing over. *)
  let project_while_paused () =
    C.projects_all
    && Rt.Fmutex.with_lock cycle_lock (fun () ->
        ignore (R.stated ~wait:true ());
        project ())

  (* Cycles until one neither pushes nor projects, for a caller that waits for
     the result. A push refused a few times in a row is left to a later call.
     A paused domain runs none (07 §2.6). *)
  let run_cycle ?narrate ?(full = false) ?(push_now = true) () =
    let rec cycles ~first ~refusals ~push_now (acc : cycled) =
      if Atomic.get paused then acc
      else (
        let arrival, changed, pushed, projected =
          step
            ?narrate:(if first then narrate else None)
            ~full:(first && full) ~push_now ()
        in
        let acc =
          {
            arrival = (if first then arrival else acc.arrival);
            changed = acc.changed + changed;
            committed =
              (acc.committed + match pushed with `Committed _ -> 1 | _ -> 0);
          }
        in
        match pushed with
          | `Committed _ -> cycles ~first:false ~refusals ~push_now acc
          | `Refused when refusals > 0 ->
              cycles ~first:false ~refusals:(refusals - 1) ~push_now acc
          | `Refused -> cycles ~first:false ~refusals ~push_now:false acc
          | `Nothing ->
              if projected then cycles ~first:false ~refusals ~push_now acc
              else acc)
    in
    cycles ~first:true ~refusals:3 ~push_now
      { arrival = `Entries 0; changed = 0; committed = 0 }

  let request_cycle () =
    Atomic.set asked true;
    wake_cycle ()

  let nudged = Atomic.make false

  let nudge () =
    Atomic.set nudged true;
    wake_cycle ()

  (* publication §4, CYCLE. A lazy tree fetches nothing on the cursor or on a
     timer (§4.11): its loop wakes to push. *)
  let cycle_loop () =
    let cursor = ref None
    and last = ref neg_infinity
    and dirty_since = ref None
    (* Whether the last cycle pushed or projected, so that the next follows at
       once, and the pushes refused in a row. *)
    and again = ref false
    and refused = ref 0
    and failing = ref None
    (* The requests the running step took, given back when it fails. *)
    and took_asked = ref false
    and took_nudged = ref false in
    (* A lazy tree cycles on no timer: its first cycle, which recovers an
       in-flight record and projects an entry a crash left, is asked for. *)
    if C.lazy_tree then Atomic.set nudged true;
    (* publication §4.5, "when": how long a push waits from [dirty_since]. The
       commands whose upload is owed are not pushable and do not fill an entry. *)
    let push_delay () =
      if
        Sync_state.pending_count sync_state - Dqueue.pending uploads
        >= (tuning ()).max_entry_commands
      then retry_floor
      else (tuning ()).batch_delay
    in
    let rec loop () =
      Stop.check ();
      took_asked := false;
      took_nudged := false;
      if Atomic.get paused then (
        if
          not
            (try project_while_paused () with
              | Stop.Stopping as e -> raise e
              | _ -> false)
        then Stop.sleep 1.;
        loop ())
      else (
        let since = Rt.Signal.version cycle_signal in
        let wait =
          match !dirty_since with
            | Some at ->
                (* A configuration the main refuses fails the step below, where
                   it is reported; it must not end the loop here. *)
                let delay =
                  try push_delay () with
                    | (Stop.Stopping | Rt.Cancelled) as e -> raise e
                    | _ -> retry_floor
                in
                max 0.05 (min sweep (delay -. (Rt.now () -. at)))
            | None -> sweep
        in
        (* A request made before [since] was read sent its wake before it
           too: the wait would not see it (pitfall A-2.8). *)
        if not (!again || Atomic.get asked || Atomic.get nudged) then (
          try
            Rt.first ~detach:true
              ((if C.lazy_tree then []
                else [(fun () -> Log_store.cursor_wait log !cursor)])
              @ [
                  (fun () -> Rt.Signal.wait ~since cycle_signal);
                  (fun () -> Stop.sleep wait);
                ])
          with
            | Stop.Stopping -> raise Stop.Stopping
            | _ -> ());
        (* 07 §2.6: a pause made during the wait holds the cycle that was
           due. *)
        if not (Atomic.get paused) then (
          match
            let token =
              if C.lazy_tree then None else Log_store.cursor_token log
            in
            if Sync_state.pending_count sync_state > 0 && !dirty_since = None
            then dirty_since := Some (Rt.now ());
            let push_due =
              match !dirty_since with
                | Some at -> Rt.now () -. at >= push_delay ()
                | None -> false
            in
            let was_asked = Atomic.exchange asked false in
            let was_nudged = Atomic.exchange nudged false in
            took_asked := was_asked;
            took_nudged := was_nudged;
            let ran = !again || was_nudged in
            again := false;
            if
              was_asked || push_due || ran
              || (not C.lazy_tree)
                 && (token <> !cursor || Rt.now () -. !last >= sweep)
            then (
              last := Rt.now ();
              let _, _, pushed, projected =
                step ~push_now:(was_asked || push_due) ()
              in
              cursor := token;
              let pending = Sync_state.pending_count sync_state > 0 in
              (match pushed with
                | `Committed _ ->
                    refused := 0;
                    (* What is left was due with what was pushed. *)
                    if not pending then dirty_since := None
                    else if was_asked then Atomic.set asked true
                | `Refused ->
                    incr refused;
                    (* publication §4.5: refused that often, the push is left
                       to the next delay, not tried again at every wake. *)
                    if !refused > 3 then dirty_since := Some (Rt.now ())
                | `Nothing ->
                    refused := 0;
                    if was_asked || push_due then
                      dirty_since := if pending then Some (Rt.now ()) else None);
              again :=
                projected
                ||
                  match pushed with
                  | `Committed _ -> true
                  | `Refused -> !refused <= 3
                  | `Nothing -> false)
          with
            | () ->
                if !failing <> None then Log.info "cycles run again";
                failing := None;
                Atomic.set cycle_failing None
            | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
            | exception e ->
                let reason = Printexc.to_string e in
                if !failing <> Some reason then
                  Log.info "cycle failed, retrying until it runs: %s" reason;
                failing := Some reason;
                Atomic.set cycle_failing (Some reason);
                if !took_asked then Atomic.set asked true;
                if !took_nudged then Atomic.set nudged true;
                Stop.sleep retry_floor);
        loop ())
    in
    try loop () with Stop.Stopping -> ()

  (* publication §4.8 steps 1 to 5, at ownership start; the in-flight record
     waits for the first cycle. *)
  let recover_local () =
    List.iter
      (fun id ->
        match Dqueue.Records.read intents id with
          | `Gone -> ()
          | `Body body -> (
              match Local_ops.decode_intent body with
                | None -> Dqueue.Records.set_aside intents id
                | Some op ->
                    with_meta (fun () -> redo op);
                    Dqueue.Records.complete intents id))
      (Dqueue.Records.list intents);
    complete_arrival ();
    with_meta (fun () ->
        List.iter
          (fun c ->
            if null c then Sync_state.drop sync_state (Algebra.key_of c))
          (pending ());
        List.iter
          (fun (path, (_ : Staged.edit)) ->
            match place_opt path with
              | None -> ()
              | Some p ->
                  if
                    (* publication §4.8 steps 3 and 4. *)
                    Sync_state.before_file sync_state p = None
                  then
                    with_key path (fun () ->
                        promote_clean path;
                        if Staged.edit staged path <> None then
                          Sync_state.record_file sync_state p
                            (mirror_value path)))
          (Staged.edits staged));
    let recorded =
      List.filter_map
        (fun id ->
          match Dqueue.Records.read upload_log id with
            | `Body body ->
                Option.map
                  (fun (u : Local_ops.upload) -> u.file)
                  (Local_ops.upload_kind.decode body)
            | `Gone -> None)
        (Dqueue.Records.list upload_log)
    in
    List.iter
      (fun (path, (e : Staged.edit)) ->
        match place_opt path with
          | Some place when e.state = Owed && not (List.mem place recorded) ->
              post_put path
          | _ -> ())
      (Staged.edits staged)
end
