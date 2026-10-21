(* extensions README §4: an extension's records in its folder, opened under the
   vault's K, settled by its format merge before a verb reads them, written
   sealed. What every extension shares; each instantiates it with its record. *)
open Tsync_core
module Fold = Tsync_vault.Fold
module Envelope = Tsync_vault.Envelope

module type RECORD = sig
  type t

  (** The extension. *)
  val name : string

  val of_string : string -> (t, string) result
  val to_string : t -> string

  (** The grouped fold's key fields (README §4.3). *)
  val key_fields : t -> string

  val modified : t -> int

  (** The record kept from a conflicted copy, labelled with [suffix]; [None]
      when its label already ends with it. *)
  val relabel : suffix:string -> t -> t option
end

module Make (R : RECORD) = struct
  let name = R.name
  let folder = Names.join Names.extension_root name

  let check_uses ~(domain : Tsync_domain.Domain.t) ~engine =
    if not (List.mem name (Vault.extensions ~domain ~engine)) then
      Fail.invalid "%s does not use %s: add it to its extensions in the config"
        (Domain_name.to_string domain.name)
        name

  type ctx = {
    domain : string;
    vault : Vault.t;
    background : bool;
        (** android §3.2 rule 1: a body not on this machine is not waited for *)
    engine : (module Tsync_sync.Engine.S);
    key : string;
    key_id : string;
    opened : (string, R.t option) Hashtbl.t;
        (** by body: a verb opens each body once, the fold's included *)
    keep : bool;  (** a lazy tree: bodies read stay pinned (README §4.1) *)
    writable : bool;  (** format-merge §2: a fold is applied only then *)
  }

  let opened ctx (f : Fold.file) =
    match Hashtbl.find_opt ctx.opened f.body with
      | Some r -> r
      | None ->
          let r =
            match
              Envelope.open_ ~key:ctx.key ~key_id:ctx.key_id ~extension:name
                f.body
            with
              | Ok plaintext -> Result.to_option (R.of_string plaintext)
              | Error _ -> None
          in
          Hashtbl.replace ctx.opened f.body r;
          r

  let seal ctx record =
    Envelope.seal ~key:ctx.key ~key_id:ctx.key_id ~extension:name
      (R.to_string record)

  (* totp §3: a record moved from a conflicted copy to a digest id (rule 5)
     says the client it came from. A write after the fold, which sealing makes
     no function of the bytes; concurrent relabels write the same plaintext. *)
  let relabel ctx = function
    (* A copy's name starts with its record id: rule 4 moves it back there. *)
    | Fold.Move { src; dst }
      when Fold.copied_from src <> None && dst <> String.sub src 0 32 -> (
        let client = Option.get (Fold.copied_from src) in
        let suffix = Printf.sprintf " (conflicted copy from %s)" client in
        let path = Names.join folder dst in
        let file =
          { Fold.name = dst; body = Vault.read_file ctx.engine path }
        in
        match Option.bind (opened ctx file) (R.relabel ~suffix) with
          | Some r ->
              Format_merge.write_file ctx.engine ~exclusive:false path
                (seal ctx r)
          | None -> ())
    | _ -> ()

  (* README §4.3, run before a verb reads: what a fold settles is never shown
     twice. *)
  let settled ctx =
    let read () = Vault.files ~keep:ctx.keep ctx.engine folder in
    match
      Format_merge.settle_folder ~after:(relabel ctx) ~writable:ctx.writable
        ~read
        ~fold:
          (Fold.grouped ~open_:(opened ctx) ~key:R.key_fields
             ~modified:R.modified)
        ctx.engine folder
    with
      | Some files -> files
      | None -> read ()

  (* README §4.1: a read answers the last view of the vault's folders and this
     one; a write proceeds on it, pushed later. *)
  let context ?(writing = false) ?use ?pull ~domain ~engine ~lazy_tree t =
    check_uses ~domain ~engine;
    let keyring, key = Vault.held ?use ?pull ~domain ~engine ~lazy_tree t in
    if lazy_tree then (
      let (module E : Tsync_sync.Engine.S) = engine in
      if not writing then
        Vault.read_folders ?pull engine t (Vault.vault_folders @ [folder])
        (* The first record makes the folder: nothing to pull yet. *)
      else if E.kind folder = `Dir then Vault.before_write t folder);
    {
      domain = Vault.key_entry domain;
      vault = t;
      background = lazy_tree && pull = Some `Background;
      engine;
      key;
      key_id = keyring.Tsync_vault.Keyring.key_id;
      opened = Hashtbl.create 16;
      keep = lazy_tree;
      writable = not domain.Tsync_domain.Domain.domain.read_only;
    }

  let now () = int_of_float (Unix.time ())

  let write ctx ~exclusive id record =
    let (module E : Tsync_sync.Engine.S) = ctx.engine in
    List.iter
      (fun dir -> E.mkdir dir ~exclusive:false)
      [Names.extension_root; folder];
    Format_merge.write_file ctx.engine ~exclusive (Names.join folder id)
      (seal ctx record)

  (* README §4.6: each record as opened, by domain and file, until its K is
     forgotten. [pinned] is when a lazy tree's pin was last renewed (§4.5). *)
  type cached = {
    version : string * string option * int * float * bool;
    key_id : string;
    record : R.t option;
    pinned : float;
  }

  let cache : (string * string, cached) Hashtbl.t = Hashtbl.create 64
  let cache_lock = Mutex.create ()

  let () =
    Vault.when_forgotten (fun domain ->
        Mutex.protect cache_lock (fun () ->
            Hashtbl.filter_map_inplace
              (fun (d, _) c -> if d = domain then None else Some c)
              cache))

  (* README §4.1: bodies a background read left out, fetched after its answer
     and opened into the cache, outside the folders' locks: a fetch writes no
     record, and what it caches is keyed by the version it read. *)
  (* README §4.5 PREFETCH_WORKERS. *)
  let prefetch_workers = 4
  let prefetching : (string, unit) Hashtbl.t = Hashtbl.create 64
  let prefetch_lock = Mutex.create ()

  let prefetch ctx missing =
    let (module E : Tsync_sync.Engine.S) = ctx.engine in
    let todo =
      Mutex.protect prefetch_lock (fun () ->
          List.filter
            (fun (name, _) ->
              let fresh = not (Hashtbl.mem prefetching name) in
              if fresh then Hashtbl.replace prefetching name ();
              fresh)
            missing)
    in
    let fetch (name, version) =
      let path = Names.join folder name in
      E.pin path ~keep:Vault.record_keep;
      let body = Vault.read_file ctx.engine path in
      let record = opened ctx { Fold.name; body } in
      Mutex.protect cache_lock (fun () ->
          Hashtbl.replace cache (ctx.domain, name)
            {
              version;
              key_id = ctx.key_id;
              record;
              pinned = Unix.gettimeofday ();
            })
    in
    if todo <> [] then (
      let queue = Queue.of_seq (List.to_seq todo) in
      let next () =
        Mutex.protect prefetch_lock (fun () -> Queue.take_opt queue)
      in
      let rec work () =
        match next () with
          | None -> ()
          | Some ((name, _) as item) ->
              Fun.protect
                ~finally:(fun () ->
                  Mutex.protect prefetch_lock (fun () ->
                      Hashtbl.remove prefetching name))
                (fun () ->
                  (* Offline, gone or locked meanwhile: the next read asks again. *)
                  try fetch item with Fail.E _ -> ());
              work ()
      in
      Rt.spawn ~name:"record prefetch" (fun () ->
          ignore (Rt.all (List.init prefetch_workers (fun _ -> work)))))

  (* README §4.6, no copy to settle: a read of each file not opened at this
     version. A background read leaves out what is not on this machine and
     says the answer is outdated. *)
  let listed ctx entries =
    let (module E : Tsync_sync.Engine.S) = ctx.engine in
    let now = Unix.gettimeofday () in
    let missing = ref [] in
    List.filter_map
      (fun (name, is_dir, (st : Tsync_sync.Local_ops.stat)) ->
        if is_dir || not (Fold.is_record_id name) then None
        else (
          let version =
            Tsync_sync.Local_ops.
              (st.etag, st.content_id, st.size, st.mtime, st.staged)
          in
          let path = Names.join folder name in
          let key = (ctx.domain, name) in
          let hit =
            Mutex.protect cache_lock (fun () -> Hashtbl.find_opt cache key)
          in
          let pin () = if ctx.keep then E.pin path ~keep:Vault.record_keep in
          match hit with
            | Some c when c.version = version && c.key_id = ctx.key_id ->
                if ctx.keep && now -. c.pinned > Vault.record_keep /. 2. then (
                  pin ();
                  Mutex.protect cache_lock (fun () ->
                      Hashtbl.replace cache key { c with pinned = now }));
                Some (name, c.record)
            | _ when ctx.background && E.availability path = `Online_only ->
                missing := (name, version) :: !missing;
                None
            | _ ->
                let body = Vault.read_file ctx.engine path in
                pin ();
                let record = opened ctx { Fold.name; body } in
                Mutex.protect cache_lock (fun () ->
                    Hashtbl.replace cache key
                      { version; key_id = ctx.key_id; record; pinned = now });
                Some (name, record)))
      entries
    |> fun found ->
    if !missing <> [] then (
      Atomic.set ctx.vault.view
        { (Atomic.get ctx.vault.view) with outdated = true };
      prefetch ctx !missing);
    found

  (* Records that open, by id, and the ids that do not. *)
  let records ctx =
    let (module E : Tsync_sync.Engine.S) = ctx.engine in
    let entries =
      if E.kind folder <> `Dir then []
      else
        List.map
          (fun (e : E.entry) -> (e.name, e.is_dir, e.st))
          (E.list_children folder)
    in
    let opened_files =
      if
        List.exists
          (fun (name, is_dir, _) -> (not is_dir) && Format_merge.is_copy name)
          entries
      then
        List.filter_map
          (fun (f : Fold.file) ->
            if Fold.is_record_id f.name then Some (f.name, opened ctx f)
            else None)
          (settled ctx)
      else listed ctx entries
    in
    List.fold_left
      (fun (ok, corrupt) (name, record) ->
        match record with
          | Some r -> ((name, r) :: ok, corrupt)
          | None -> (ok, name :: corrupt))
      ([], []) opened_files
    |> fun (ok, corrupt) -> (List.rev ok, List.sort compare corrupt)

  let find ctx id =
    if not (Fold.is_record_id id) then Fail.invalid "%S is not a record id" id;
    let ok, corrupt = records ctx in
    match List.assoc_opt id ok with
      | Some r -> r
      | None when List.mem id corrupt ->
          Fail.corrupt "%s does not open under this vault's key" id
      | None -> Fail.absent "no record %s" id

  (* Removing needs no plaintext, so a record that does not open goes too. *)
  let remove ~domain ~engine ~lazy_tree t id =
    let ctx = context ~writing:true ~domain ~engine ~lazy_tree t in
    (match find ctx id with
      | _ -> ()
      | exception Fail.E { kind = Corrupt; _ } -> ());
    let (module E : Tsync_sync.Engine.S) = engine in
    E.delete (Names.join folder id)

  (* README §4.2: the fold that waited for the key, run by an arrival only
     while K is held, so it never reads the keystore or counts as a use. *)
  let fold ~domain ~engine ~lazy_tree t =
    if
      Atomic.get t.Vault.key <> None
      && List.mem name (Vault.extensions ~domain ~engine)
    then ignore (records (context ~use:false ~domain ~engine ~lazy_tree t))
end
