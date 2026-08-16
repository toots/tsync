open Lwt.Syntax

type dest_stats = {
  name : string;
  checked : int;
  copied : int;
  copied_bytes : int;
}

type phase = [ `Listing | `Comparing | `Copying ]

type progress = {
  phase : phase;
  store : string;
  done_ : int;
  total : int option;
}

let string_of_phase = function
  | `Listing -> "listing"
  | `Comparing -> "comparing"
  | `Copying -> "copying"

(* Named so that the several functions taking one can say so: an optional
   argument on an inferred function type has to be applied the same way
   everywhere, and [force] is passed only at a phase's last call. *)
type reporter =
  ?force:bool ->
  phase:phase ->
  store:string ->
  done_:int ->
  total:int option ->
  unit ->
  unit

module Make (C : Conf.S) = struct
  module Space = Chunk_space.Make (C)
  module Tree = Inode_tree.Make (C)

  (* A copy holds the whole object body, and holds it across the puts to every
     destination that needs it, so this follows [max_chunk_buffers] rather than
     the file-level [max_uploads]. *)
  let copy_pool = Lwt_bounded.create ~max:C.max_chunk_buffers ()

  (* A listing holds a page and a descriptor, not a body, so it is bounded apart
     from the copies. Wide enough for the (store x namespace) pairs a sane
     config has, narrow enough that a domain with a dozen stores does not open a
     listing against every one of them at once. *)
  let list_pool = Lwt_bounded.create ~max:8 ()

  (* A HEAD holds nothing at all, and [`Path] is made of them: at
     [max_chunk_buffers] a scoped resync of a large folder runs four round trips
     wide. *)
  let probe_pool = Lwt_bounded.create ~max:32 ()
  let spool_dir = Filename.concat C.cache_root "mirror"

  (* A clock per phase: phases overlap, and one whose first item lands inside
     another's interval would report nothing until a second went by — which is
     what copying does, beginning as the listing that fed it ends. *)
  let reporter on_progress : reporter =
    let pace = Pace.create () in
    fun ?(force = false) ~phase ~store ~done_ ~total () ->
      Pace.fire pace ~key:(string_of_phase phase) ~force (fun () ->
          on_progress { phase; store; done_; total })

  let namespaces ~manifests_only =
    if manifests_only then [("manifests", C.domain_prefix)]
    else
      [
        ("manifests", C.domain_prefix);
        ("chunks", C.chunk_prefix);
        ("journal", C.journal_prefix);
        ("versions", C.versions_prefix);
      ]

  (* The four prefixes are disjoint by construction, so a key belongs to exactly
     one of them and the join never needs an order across two. *)
  let list_namespace ~(report : reporter) ~store_name ~prefix ~ns
      (module B : Backend.S) =
    let label = Printf.sprintf "%s on %s" ns store_name in
    let* spool = Listing_spool.create ~dir:spool_dir ~label in
    Lwt.catch
      (fun () ->
        let seen = ref 0 in
        let* () =
          B.fold_prefix ~prefix
            ~f:(fun page ->
              seen := !seen + List.length page;
              report ~phase:`Listing ~store:label ~done_:!seen ~total:None ();
              Listing_spool.add spool page)
            ()
        in
        report ~force:true ~phase:`Listing ~store:label ~done_:!seen ~total:None
          ();
        Listing_spool.seal spool)
      (fun exn ->
        let* () = Listing_spool.discard spool in
        Lwt.fail exn)

  (* [rel] itself and everything under it. *)
  let within ~rel path =
    rel = "" || path = rel || String.starts_with ~prefix:(rel ^ "/") path

  (* A folder [rel] sits inside: descended into, but nothing of its own is
     taken. *)
  let holds ~rel path = String.starts_with ~prefix:(path ^ "/") rel

  let chunk_keys (m : Manifest.t) =
    let table = m.Manifest.chunks in
    List.init (Chunk_table.count table) (fun i ->
        Space.key (Chunk_table.key table i))

  (* Only the folders [rel] runs through or lives in are descended into, so
     scoping to one folder costs its own subtree rather than the whole tree. A
     file brings the chunks it names: manifests alone would copy a listing the
     far side cannot read a byte of.

     Journal, versions and cursor are left out — they describe the domain, not
     this subtree, and copying part of a journal would state a history that never
     happened. *)
  let path_keys ~rel =
    let rec walk folder_id here acc =
      let* entries = Tree.children ~folder_id () in
      Lwt_list.fold_left_s
        (fun acc (entry : Inode_tree.entry) ->
          match entry.Inode_tree.body with
            | Inode_tree.Dir m ->
                let path = Key.join here m.Folder.name in
                if within ~rel path then
                  walk m.Folder.id path (entry.Inode_tree.bkey :: acc)
                else if holds ~rel path then walk m.Folder.id path acc
                else Lwt.return acc
            | Inode_tree.File m ->
                let path = Key.join here (Manifest.recorded_name m) in
                if within ~rel path then
                  Lwt.return (chunk_keys m @ (entry.Inode_tree.bkey :: acc))
                else Lwt.return acc)
        acc entries
    in
    let+ keys = walk Folder.root_id "" [] in
    List.sort_uniq compare keys

  type target = { t_name : string; store : (module Backend.S) }

  type need = { key : string; is_dir : bool; wanted : (int * reason) list }
  and reason = [ `Missing | `Wrong_size ]

  type tally = { mutable n_copied : int; mutable n_bytes : int }

  (* Items, holding no bodies: a copy pool slot is what holds one, so this only
     decides how often the compare loop stops to run what it has found. *)
  let batch_size = 512

  (* Fetched once whatever the destination count: an object missing on two
     targets is one body off the source, not two. *)
  let run_batch ~(report : reporter) ~fetched ~src ~dests ~tallies ~on_copy
      items =
    let put_all (n : need) data ~bytes =
      Lwt_list.iter_p
        (fun (i, reason) ->
          let (module D : Backend.S) = dests.(i).store in
          let+ () = D.put ~key:n.key ~data () in
          let t = tallies.(i) in
          t.n_copied <- t.n_copied + 1;
          t.n_bytes <- t.n_bytes + bytes;
          on_copy ~name:dests.(i).t_name ~key:n.key ~reason ~bytes)
        n.wanted
    in
    Lwt_bounded.iter_with copy_pool
      (fun (n : need) ->
        let* () =
          if n.is_dir then put_all n Chunk.empty ~bytes:0
          else (
            let (module S : Backend.S) = src in
            let* data = S.get ~key:n.key () in
            put_all n data ~bytes:(Chunk.length data))
        in
        incr fetched;
        report ~phase:`Copying ~store:n.key ~done_:!fetched ~total:None ();
        Lwt.return_unit)
      items

  (* One source cursor against every destination's at once. A destination key
     below the source's is one the source does not have: mirror is additive, so
     it is stepped over rather than deleted. *)
  let compare_namespace ~(report : reporter) ~ns ~src_spool ~dst_spools ~run =
    let src = Listing_spool.cursor src_spool in
    let dsts = Array.map Listing_spool.cursor dst_spools in
    let total = Listing_spool.count src_spool in
    let pending = ref [] and pending_len = ref 0 and examined = ref 0 in
    let rec loop () =
      if Listing_spool.at_end src then
        if !pending = [] then Lwt.return_unit else flush ()
      else begin
        let is_dir = Listing_spool.key_is_dir src in
        let size = Listing_spool.size src in
        let wanted = ref [] in
        Array.iteri
          (fun i d ->
            while
              (not (Listing_spool.at_end d)) && Listing_spool.compare d src < 0
            do
              Listing_spool.advance d
            done;
            if Listing_spool.at_end d || Listing_spool.compare d src > 0 then
              wanted := (i, `Missing) :: !wanted
            else begin
              let same_size = Listing_spool.size d = size in
              Listing_spool.advance d;
              if (not is_dir) && not same_size then
                wanted := (i, `Wrong_size) :: !wanted
            end)
          dsts;
        incr examined;
        report ~phase:`Comparing ~store:ns ~done_:!examined ~total:(Some total)
          ();
        if !wanted <> [] then begin
          pending :=
            { key = Listing_spool.key src; is_dir; wanted = List.rev !wanted }
            :: !pending;
          incr pending_len
        end;
        Listing_spool.advance src;
        if !pending_len >= batch_size then
          let* () = flush () in
          loop ()
        else loop ()
      end
    and flush () =
      let items = List.rev !pending in
      pending := [];
      pending_len := 0;
      run items
    in
    let* () = loop () in
    report ~force:true ~phase:`Comparing ~store:ns ~done_:!examined
      ~total:(Some total) ();
    Lwt.return total

  (* Copies between the stores themselves rather than through {!Conf.store}: the
     point is to reach the ones the composite writes off the caller's path, or
     does not write at all. Raises [Failure] when nothing has that name. *)
  let rec resync ?source ?(scope = `All) ?(on_scan = fun ~objects:_ -> ())
      ?(on_list = fun ~name:_ -> ()) ?(on_progress = fun (_ : progress) -> ())
      ?(on_copy = fun ~name:_ ~key:_ ~reason:_ ~bytes:_ -> ()) () =
    let named name =
      match
        List.filter
          (fun (m : Backend.member) -> m.Backend.name = name)
          C.members
      with
        | [m] -> m
        | [] ->
            failwith
              (Printf.sprintf "no backend named %s (available: %s)" name
                 (String.concat ", "
                    (List.map (fun (m : Backend.member) -> m.name) C.members)))
        | _ ->
            failwith
              (Printf.sprintf
                 "backend name %s is ambiguous; set distinct \"name\" fields \
                  in the config"
                 name)
    in
    let src_member =
      match (source, C.members) with
        | Some name, _ -> named name
        | None, m :: _ -> m
        | None, [] -> failwith "no backends configured"
    in
    let src = src_member.Backend.backend in
    let dests =
      C.members
      |> List.filter (fun (m : Backend.member) ->
          m.Backend.name <> src_member.Backend.name)
      |> List.map (fun (m : Backend.member) ->
          { t_name = m.Backend.name; store = m.Backend.backend })
      |> Array.of_list
    in
    let tallies = Array.map (fun _ -> { n_copied = 0; n_bytes = 0 }) dests in
    let report = reporter on_progress in
    (* Objects taken off the source, which is what a copying phase advances by;
       a destination's own count is [tallies], and the two differ by however
       many destinations each object was missing from. *)
    let fetched = ref 0 in
    let run items =
      run_batch ~report ~fetched ~src ~dests ~tallies ~on_copy items
    in
    (* A collection in progress leaves the chunk prefix holding only what has
       been marked so far, so listing it would copy a partial chunk set to every
       target and call it a resync. *)
    let* () =
      let* run = Space.read_run () in
      match (run, scope) with
        | None, _ | Some _, `Manifests -> Lwt.return_unit
        | Some r, (`All | `Path _) ->
            failwith
              (Printf.sprintf
                 "%s is being collected (%s, started %.0fs ago), so its chunks \
                  are only partly under the usual prefix. Let tsync gc finish, \
                  or stop it with tsync gc --abort, then resync."
                 C.domain_name
                 (Chunk_space.string_of_phase r.Chunk_space.phase)
                 (Unix.gettimeofday () -. r.Chunk_space.started))
    in
    let* () = Listing_spool.sweep ~dir:spool_dir in
    let checked = ref 0 in
    let finish () =
      Array.to_list
        (Array.mapi
           (fun i (d : target) ->
             {
               name = d.t_name;
               checked = !checked;
               copied = tallies.(i).n_copied;
               copied_bytes = tallies.(i).n_bytes;
             })
           dests)
    in
    match scope with
      | `Path rel ->
          let+ () =
            scoped_resync ~rel ~report ~run ~src
              ~src_name:src_member.Backend.name ~dests ~on_list ~on_scan
              ~checked
          in
          finish ()
      | (`All | `Manifests) as scope ->
          let manifests_only = scope = `Manifests in
          let+ () =
            namespace_resync ~manifests_only ~report ~run ~fetched ~src ~dests
              ~on_list ~on_scan ~on_copy ~tallies ~checked
              ~src_name:src_member.Backend.name
          in
          finish ()

  (* Every (store x namespace) listing is spooled first, then each namespace is
     joined on its own: the cost is one listing per store per namespace rather
     than a HEAD per object per destination. *)
  and namespace_resync ~manifests_only ~(report : reporter) ~run ~fetched ~src
      ~dests ~on_list ~on_scan ~on_copy ~tallies ~checked ~src_name =
    let nss = namespaces ~manifests_only in
    let sides =
      (src_name, src, `Source)
      :: Array.to_list
           (Array.mapi
              (fun i (d : target) -> (d.t_name, d.store, `Dest i))
              dests)
    in
    let jobs =
      List.concat_map
        (fun (ns, prefix) ->
          List.map
            (fun (name, store, role) -> (ns, prefix, name, store, role))
            sides)
        nss
    in
    List.iter (fun (ns, _) -> on_list ~name:("listing " ^ ns)) nss;
    let* listed =
      Lwt_bounded.map_with list_pool
        (fun (ns, prefix, name, store, role) ->
          let+ spool =
            list_namespace ~report ~store_name:name ~prefix ~ns store
          in
          (ns, role, spool))
        jobs
    in
    let all_spools = List.map (fun (_, _, s) -> s) listed in
    Lwt.finalize
      (fun () ->
        let objects =
          List.fold_left
            (fun acc (_, role, s) ->
              if role = `Source then acc + Listing_spool.count s else acc)
            0 listed
        in
        on_scan ~objects;
        let* () =
          Lwt_list.iter_s
            (fun (ns, _) ->
              let of_ns role =
                List.filter_map
                  (fun (n, r, s) -> if n = ns && r = role then Some s else None)
                  listed
              in
              match of_ns `Source with
                | [src_spool] ->
                    let dst_spools =
                      Array.init (Array.length dests) (fun i ->
                          match of_ns (`Dest i) with
                            | [s] -> s
                            | _ -> assert false)
                    in
                    let+ n =
                      compare_namespace ~report ~ns ~src_spool ~dst_spools ~run
                    in
                    checked := !checked + n
                | _ -> assert false)
            nss
        in
        (* Not under any listed prefix, and one key: a HEAD on each side is the
           whole of it. *)
        if manifests_only then Lwt.return_unit
        else sync_cursor ~report ~fetched ~src ~dests ~tallies ~on_copy ~checked)
      (fun () -> Lwt_list.iter_s Listing_spool.remove all_spools)

  and sync_cursor ~(report : reporter) ~fetched ~src ~dests ~tallies ~on_copy
      ~checked =
    let (module S : Backend.S) = src in
    let* head = S.head_opt ~key:C.cursor_key () in
    match head with
      | None -> Lwt.return_unit
      | Some entry ->
          incr checked;
          let* wanted =
            Lwt_bounded.filter_map_with probe_pool
              (fun i ->
                let (module D : Backend.S) = dests.(i).store in
                let+ h = D.head_opt ~key:C.cursor_key () in
                match h with
                  | None -> Some (i, `Missing)
                  | Some h when h.Backend.size <> entry.Backend.size ->
                      Some (i, `Wrong_size)
                  | Some _ -> None)
              (List.init (Array.length dests) Fun.id)
          in
          if wanted = [] then Lwt.return_unit
          else
            run_batch ~report ~fetched ~src ~dests ~tallies ~on_copy
              [{ key = C.cursor_key; is_dir = false; wanted }]

  (* A folder is not a namespace: listing a destination's whole chunk store to
     check the handful of chunks one folder names is the opposite trade from
     [`All], so this probes by key on both sides.

     The source probe is not overhead — it is what produces both the size and
     the failure below, this command copying a full backend onto a partial
     one. *)
  and scoped_resync ~rel ~(report : reporter) ~run ~src ~src_name ~dests
      ~on_list ~on_scan ~checked =
    on_list ~name:(Printf.sprintf "walking the tree under %s" rel);
    let* keys = path_keys ~rel in
    let total = List.length keys in
    on_list
      ~name:
        (Printf.sprintf "sizing %d object%s on %s" total
           (if total = 1 then "" else "s")
           src_name);
    on_scan ~objects:total;
    let (module S : Backend.S) = src in
    let examined = ref 0 in
    let probe key =
      let* head = Lwt_bounded.use probe_pool (fun () -> S.head_opt ~key ()) in
      match head with
        | None ->
            Lwt.fail
              (Failure
                 (Printf.sprintf "%s is missing from source %s" key src_name))
        | Some entry ->
            let is_dir = Key.is_dir key in
            let+ wanted =
              Lwt_bounded.filter_map_with probe_pool
                (fun i ->
                  let (module D : Backend.S) = dests.(i).store in
                  let+ h = D.head_opt ~key () in
                  match h with
                    | None -> Some (i, `Missing)
                    | Some h
                      when (not is_dir) && h.Backend.size <> entry.Backend.size
                      ->
                        Some (i, `Wrong_size)
                    | Some _ -> None)
                (List.init (Array.length dests) Fun.id)
            in
            incr examined;
            report ~phase:`Comparing ~store:rel ~done_:!examined
              ~total:(Some total) ();
            if wanted = [] then None else Some { key; is_dir; wanted }
    in
    (* Not [Lwt_bounded.filter_map_with probe_pool]: [probe] takes from that
       same pool, and a slot held around work asking for one deadlocks. The
       batch is what bounds this, the pool what bounds the round trips. *)
    let rec batches = function
      | [] -> Lwt.return_unit
      | keys ->
          let batch, rest = Batch.take batch_size keys in
          let* needs = Lwt_list.filter_map_p probe batch in
          let* () = run needs in
          batches rest
    in
    let+ () = batches keys in
    checked := total;
    report ~force:true ~phase:`Comparing ~store:rel ~done_:!examined
      ~total:(Some total) ()
end
