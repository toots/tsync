(* Reading the backend's folder tree.

   A folder's children live under [manifests/<folder_id>/], each object either a
   folder marker (naming a subfolder and pointing at its namespace) or a file
   manifest, told apart only by their body. Callers keep their own folds — they
   want different things — and share only that classification step. *)

type body = Dir of Folder.marker | File of Manifest.t
type entry = { bkey : Stored_key.t; body : body }
type unusable = [ `Unreadable of exn | `Unclassifiable of exn ]
type on_unusable = [ `Fail | `Skip of Stored_key.t -> unusable -> unit ]

module type S = sig
  type 'a io
  type pool

  val namespace_prefix : string -> Stored_key.t

  val children :
    ?on_unusable:on_unusable ->
    ?refresh_index:bool ->
    ?on_index:(Stored_key.t -> unit) ->
    ?slots:pool ->
    folder_id:string ->
    unit ->
    entry list io

  val fold_tree :
    ?on_unusable:on_unusable ->
    ?refresh_index:bool ->
    ?on_index:(Stored_key.t -> unit) ->
    ?slots:pool ->
    folder_id:string ->
    key:Logical_key.t ->
    ('a -> Logical_key.t -> entry -> 'a io) ->
    'a ->
    'a io
end

module type OVER = sig
  type 'a io
  type pool

  module Make (C : Conf.S with type 'a io = 'a io) :
    S with type 'a io := 'a io and type pool = pool
end

module Over
    (Io : Io.S)
    (Pools : Bounded.S with type 'a io := 'a Io.t)
    (Tree_store :
      Store.INODE with type 'a io := 'a Io.t and type pool := Pools.t) =
struct
  type pool = Pools.t

  open Io_syntax.Make (Io)

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    type pool = Pools.t

    module St = Tree_store.Make (C)

    let namespace_prefix folder_id =
      Stored_key.namespace ~prefix:C.domain_prefix ~folder_id

    (* The domain's download budget, since a child is one object read like any
       other, and shared so a resync, a mirror and a share server in one process
       bound each other rather than each holding a budget of its own. *)
    let default_slots =
      lazy
        (Pools.shared ~key:C.domain_prefix ~name:"tree reads"
           ~max:C.max_downloads ())

    (* An index pairs a body with the version the listing gave it, so both have to
       come from the same store. A domain's stores are presented as one, and a
       read falls through to the next where the listing does not: with more than
       one place a read can land, a body answered by the second store would be
       recorded under the first's version and served in its place ever after.

       Read as well as written under this, so a domain that gains a second
       readable store stops trusting what it wrote while it had one. *)
    let one_source =
      lazy
        (List.length
           (List.filter
              (fun (m : (module C.Store) Backend.member) -> m.Backend.readable)
              C.members)
        = 1)

    let classify data =
      match Folder.marker_of_string data with
        | Some m -> Ok (Dir m)
        | None -> (
            match Manifest.of_string data with
              | m -> Ok (File m)
              | exception exn -> Error exn)

    (* The index is listed with the children it describes, so having it costs no
       round trip to discover. An unreadable one is one we do not have. *)
    let read_index ~slots listed =
      if
        (not (Lazy.force one_source))
        || not
             (List.exists
                (fun (e : Backend.file_entry) ->
                  Stored_key.is_index_key e.Backend.key)
                listed)
      then Io.return Folder_index.empty
      else
        Io.catch
          (fun () ->
            let indexed =
              List.filter
                (fun (e : Backend.file_entry) ->
                  Stored_key.is_index_key e.Backend.key
                  && e.Backend.size <= Folder_index.max_bytes)
                listed
            in
            let+ answered = St.get_objects ~slots ~entries:indexed () in
            match answered with
              | [(_, Some body)] -> Folder_index.of_string body
              | _ -> Folder_index.empty)
          (fun _ -> Io.return Folder_index.empty)

    (* Held against the version the listing reports now, so an entry the index
       covers is one the store still has the same body for. *)
    let cached index (e : Backend.file_entry) =
      match e.Backend.etag with
        | None -> None
        | Some etag -> Folder_index.find index ~key:e.Backend.key ~etag

    (* Written by whoever has just read the whole folder anyway, and only when
       enough of it was not covered to pay for the round trip. Best effort: a
       read must not fail because its cache could not be refreshed, and a caller
       serving a read-only domain simply never asks. *)
    let write_index ~folder_id ~index ~entries ~body_of =
      if not (Lazy.force one_source) then Io.return ()
      else (
        let indexable =
          List.filter
            (fun (e : Backend.file_entry) -> e.Backend.etag <> None)
            entries
        in
        let covered =
          List.length (List.filter (fun e -> cached index e <> None) indexable)
        in
        if
          not
            (Folder_index.worth_writing ~covered ~total:(List.length indexable))
        then Io.return ()
        else (
          let bodies =
            List.filter_map
              (fun e -> Option.map (fun b -> (e, b)) (body_of e))
              indexable
          in
          Io.catch
            (fun () ->
              St.put_raw
                ~bkey:(Stored_key.index_key ~prefix:C.domain_prefix ~folder_id)
                ~data:(Folder_index.of_bodies bodies))
            (fun exn ->
              Log.warn "folder index %s: %s" folder_id (Printexc.to_string exn);
              Io.return ())))

    (* A key listed and then gone: the listing and the reads that follow it are
       not one act, and to a walk that is a child it could not read rather than
       one that was never there. *)
    let vanished bkey =
      Retry.failed ~kind:Retry.Permanent ~op:"get"
        ("not found: " ^ Stored_key.to_string bkey)

    let child_objects listed =
      List.filter
        (fun (e : Backend.file_entry) ->
          Stored_key.is_child_object e.Backend.key)
        listed

    let tell_index on_index listed =
      List.iter
        (fun (e : Backend.file_entry) ->
          if Stored_key.is_index_key e.Backend.key then on_index e.Backend.key)
        listed

    let read_of ~body_of entries =
      List.map
        (fun (e : Backend.file_entry) ->
          let bkey = e.Backend.key in
          match body_of e with
            | Some data -> (bkey, Ok data)
            | None -> (bkey, Error (vanished bkey)))
        entries

    (* Classified once, then reported and filtered from the same list: two
       passes over [classify] would be the same rule answered twice. *)
    let classified ~on_unusable read =
      let outcome (bkey, data) =
        match data with
          | Error exn -> (bkey, Error (`Unreadable exn))
          | Ok data -> (
              match classify data with
                | Ok body -> (bkey, Ok { bkey; body })
                | Error exn -> (bkey, Error (`Unclassifiable exn)))
      in
      let outcomes = List.map outcome read in
      let kept = List.filter_map (fun (_, r) -> Result.to_option r) outcomes in
      match on_unusable with
        | `Fail -> (
            (* An unclassifiable body is a write in flight and is skipped; a read
               that failed is not, and a walk deciding what to delete must not
               take one for an absent subtree. *)
              match
                List.find_map
                  (function
                    | _, Error (`Unreadable exn) -> Some exn | _ -> None)
                  outcomes
              with
              | Some exn -> Io.fail exn
              | None -> Io.return kept)
        | `Skip f ->
            List.iter
              (function _, Ok _ -> () | bkey, Error r -> f bkey r)
              outcomes;
            Io.return kept

    (* A folder answered with its bodies, as a batched listing hands one over. *)
    let of_answered ~on_unusable ~on_index (folder : Store.listed_folder) =
      tell_index on_index folder.Store.listed;
      let fetched = Hashtbl.create (List.length folder.Store.bodies) in
      List.iter
        (fun (bkey, data) -> Hashtbl.replace fetched bkey data)
        folder.Store.bodies;
      let body_of (e : Backend.file_entry) =
        Option.join (Hashtbl.find_opt fetched e.Backend.key)
      in
      classified ~on_unusable
        (read_of ~body_of (child_objects folder.Store.listed))

    let children ?(on_unusable = `Fail) ?(refresh_index = false)
        ?(on_index = fun _ -> ()) ?slots ~folder_id () =
      let slots =
        match slots with Some s -> s | None -> Lazy.force default_slots
      in
      let* listed = St.list_namespace ~folder_id in
      tell_index on_index listed;
      let entries = child_objects listed in
      let in_one_batch () =
        let* index = read_index ~slots listed in
        let wanted = List.filter (fun e -> cached index e = None) entries in
        let* answered = St.get_objects ~slots ~entries:wanted () in
        let fetched = Hashtbl.create (List.length answered) in
        List.iter
          (fun (bkey, data) -> Hashtbl.replace fetched bkey data)
          answered;
        let body_of (e : Backend.file_entry) =
          match cached index e with
            | Some body -> Some body
            | None -> Option.join (Hashtbl.find_opt fetched e.Backend.key)
        in
        let+ () =
          if refresh_index then write_index ~folder_id ~index ~entries ~body_of
          else Io.return ()
        in
        read_of ~body_of entries
      in
      (* A batch is all or nothing, so one object that cannot be read would cost
         every sibling it was asked for alongside. Only a caller that wanted the
         rest pays this second pass, and only for a store's refusal: a link that
         stopped answering would lose every key the same way, one retry loop at
         a time. *)
      let key_by_key () =
        Pools.map_with slots
          (fun (e : Backend.file_entry) ->
            let bkey = e.Backend.key in
            Io.catch
              (fun () ->
                let+ data = St.get_object ~bkey in
                (bkey, Ok data))
              (fun exn -> Io.return (bkey, Error exn)))
          entries
      in
      let* read =
        match on_unusable with
          | `Fail -> in_one_batch ()
          | `Skip _ ->
              Io.catch in_one_batch (fun exn ->
                  if Backend.classify exn = Retry.Permanent then key_by_key ()
                  else Io.fail exn)
      in
      classified ~on_unusable read

    (* The frontier of a walk: folders known and not yet answered, in visit
       order, a folder's children taking its place when its answer arrives. *)
    type node = {
      id : string;
      mutable requested : bool;
      mutable prev : node option;
      mutable next : node option;
    }

    (* [f acc key entry] sees each entry with the key of the folder holding it. A
       folder is visited before it is descended into, so a caller collecting keys
       gets the marker too.

       Folders are fetched ahead of the visit, up to the pool's width of requests
       at once and, where the store lists many folders per request, a batch of
       them each: a fill takes the frontier's first pending folders, which are
       the ones the walk needs next. Not under a slot, since the reads inside a
       single fetch take those.

       A folder the link lost is walked again after everything else, and only a
       second loss is reported, so a burst of failures costs a retry rather than
       the run. *)
    let fold_tree ?on_unusable ?refresh_index ?on_index ?slots ~folder_id ~key f
        acc =
      let slots =
        match slots with Some s -> s | None -> Lazy.force default_slots
      in
      let on_unusable = Option.value on_unusable ~default:`Fail in
      let on_index = Option.value on_index ~default:ignore in
      let fetch folder_id =
        children ~on_unusable ?refresh_index ~on_index ~slots ~folder_id ()
      in
      let width = Pools.width slots in
      let head = ref None in
      let nodes : (string, node) Hashtbl.t = Hashtbl.create 64 in
      let unlink n =
        (match n.prev with
          | Some p -> p.next <- n.next
          | None -> head := n.next);
        (match n.next with Some x -> x.prev <- n.prev | None -> ());
        Hashtbl.remove nodes n.id
      in
      (* [ids] in order, after [at] or at the head. *)
      let insert_after at ids =
        let after = ref at in
        List.iter
          (fun id ->
            let next = match !after with Some a -> a.next | None -> !head in
            let n = { id; requested = false; prev = !after; next } in
            (match !after with
              | Some a -> a.next <- Some n
              | None -> head := Some n);
            (match next with Some x -> x.prev <- Some n | None -> ());
            Hashtbl.replace nodes id n;
            after := Some n)
          ids
      in
      let subfolders entries =
        List.filter_map
          (fun entry ->
            match entry.body with Dir m -> Some m.Folder.id | File _ -> None)
          entries
      in
      (* The answered folder gives its place to its children. *)
      let expand id entries =
        match Hashtbl.find_opt nodes id with
          | Some n ->
              insert_after (Some n) (subfolders entries);
              unlink n
          | None -> insert_after None (subfolders entries)
      in
      let pending_upto n =
        let rec go node n acc =
          if n = 0 then List.rev acc
          else (
            match node with
              | None -> List.rev acc
              | Some x ->
                  if x.requested then go x.next n acc
                  else begin
                    x.requested <- true;
                    go x.next (n - 1) (x.id :: acc)
                  end)
        in
        go !head n []
      in
      (* Answers not yet taken, each with how many folders of its request are
         still to be taken: the request is over when none is. *)
      let parked : (string, entry list Io.t * int ref) Hashtbl.t =
        Hashtbl.create 16
      in
      let requests = ref 0 in
      let park ids answer =
        let left = ref (List.length ids) in
        List.iter (fun id -> Hashtbl.replace parked id (answer id, left)) ids
      in
      let rec fill () =
        let batch =
          match St.list_many with
            | None -> 1
            | Some _ -> Backend.max_batch_folders
        in
        let rec go () =
          if !requests < width then (
            match pending_upto batch with
              | [] -> ()
              | ids ->
                  incr requests;
                  (match St.list_many with
                    | None ->
                        let answer = fetch_one (List.hd ids) in
                        park ids (fun _ -> answer)
                    | Some list_many ->
                        let answered = fetch_many list_many ids in
                        park ids (fun id ->
                            let* answered = answered in
                            match Hashtbl.find_opt answered id with
                              | Some entries -> Io.return entries
                              | None -> fetch_one id));
                  go ())
        in
        go ()
      and fetch_one id =
        let+ entries = fetch id in
        expand id entries;
        fill ();
        entries
      (* Classified on arrival; a folder the store left out keeps its place and
         is fetched singly by the promise parked for it. *)
      and fetch_many list_many ids =
        let* answered = list_many ~folder_ids:ids () in
        let+ classified =
          map_s
            (fun (folder : Store.listed_folder) ->
              let+ entries = of_answered ~on_unusable ~on_index folder in
              (folder.Store.folder_id, entries))
            answered
        in
        List.iter (fun (id, entries) -> expand id entries) classified;
        fill ();
        let table = Hashtbl.create (List.length classified) in
        List.iter
          (fun (id, entries) -> Hashtbl.replace table id entries)
          classified;
        table
      in
      (* The walk got ahead of the fill: asked for on the spot, as the root is. *)
      let take id =
        match Hashtbl.find_opt parked id with
          | Some (answer, left) ->
              Hashtbl.remove parked id;
              (* Freed once the answer is in hand rather than when it is asked
                 for, or a request still in flight would go uncounted against
                 the width and the next would start beside it. *)
              let* entries = answer in
              decr left;
              if !left = 0 then begin
                decr requests;
                fill ()
              end;
              Io.return entries
          | None ->
              Option.iter
                (fun n -> n.requested <- true)
                (Hashtbl.find_opt nodes id);
              fetch_one id
      in
      let lost = ref [] in
      let rec walk ~again folder_id key acc =
        let* entries =
          Io.catch
            (fun () -> Io.map Option.some (take folder_id))
            (fun exn ->
              match on_unusable with
                | `Skip report when Backend.classify exn = Retry.Transient ->
                    if again then
                      report (namespace_prefix folder_id) (`Unreadable exn)
                    else lost := (folder_id, key) :: !lost;
                    Io.return None
                | _ -> Io.fail exn)
        in
        match entries with
          | None -> Io.return acc
          | Some entries ->
              fold_left_s
                (fun acc entry ->
                  let* acc = f acc key entry in
                  match entry.body with
                    | Dir m ->
                        walk ~again m.Folder.id
                          (Logical_key.dir_in key m.Folder.name)
                          acc
                    | File _ -> Io.return acc)
                acc entries
      in
      let* acc = walk ~again:false folder_id key acc in
      fold_left_s
        (fun acc (folder_id, key) -> walk ~again:true folder_id key acc)
        acc (List.rev !lost)
  end
end
