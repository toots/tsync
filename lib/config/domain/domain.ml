let make_backend ~traffic (bc : Conf_parsing.backend_config) =
  Backend.make ~traffic ~backend_type:bc.backend_type
    ~get_field:(fun k -> List.assoc_opt k bc.fields)
    ()

(* Empty for a body that is not a manifest: a folder marker, a trash marker, a
   share. *)
let chunk_keys data =
  match Chunk_table.of_string data with
    | t -> List.init (Chunk_table.count t) (Chunk_table.key t)
    | exception _ -> []

(* Where the deferred targets keep what they still owe. Per domain, since the
   jobs name domain keys and a shared root would replay one domain's against
   another's backends — the same reason {!Wal} shards by domain. *)
let deferred_root ~paths (d : Conf_parsing.domain) =
  Filename.concat
    (Filename.concat paths.Runtime.data_dir "deferred-pending")
    d.Conf_parsing.name

(* The one place a configured role becomes behavior: [replica] and [backfill]
   are the same target with one bit between them — whether reads may reach it —
   so a resynced backfill is promoted by editing one word. *)
let build_backends ~paths ~resume (d : Conf_parsing.domain) :
    (module Backend.S) * Backend.member list =
  (* One counter pair per configured store, kept by name so the member built
     below reports the very counters that store's wrapper adds to. *)
  let traffic : (string, Backend.traffic) Hashtbl.t = Hashtbl.create 4 in
  (* Shared by every layer below: a second [make_backend] for the same config is
     a second client against the same store. Order comes from
     {!Conf_parsing.order_backends}, so a main answers first. *)
  let leaves =
    List.map
      (fun (bc : Conf_parsing.backend_config) ->
        let t = Backend.new_traffic () in
        Hashtbl.replace traffic bc.Conf_parsing.name t;
        (bc, make_backend ~traffic:t bc))
      (Conf_parsing.order_backends d.Conf_parsing.backends)
  in
  let of_roles rs =
    List.filter
      (fun ((bc : Conf_parsing.backend_config), _) -> List.mem bc.role rs)
      leaves
  in
  let sub ((bc : Conf_parsing.backend_config), backend) =
    { Domain_store.name = bc.Conf_parsing.name; backend }
  in
  (* Kept so [report_members] and the share list can ask a target how it is
     doing, and whether reads reach it, without re-deriving either from the
     role. *)
  let built : (string, (module Deferred.S)) Hashtbl.t = Hashtbl.create 4 in
  let target ((bc : Conf_parsing.backend_config), backend) ~source =
    let plain =
      Deferred.make ~resume ~name:bc.name ~backend ~source
        ~chunk_prefix:(Conf_parsing.chunk_prefix d)
        ~chunk_from_prefix:
          (Chunk_space.from_prefix ~chunk_prefix:(Conf_parsing.chunk_prefix d))
        ~chunk_keys
        ~journal_prefix:(Conf_parsing.journal_prefix d)
        ~cursor_key:(Conf_parsing.cursor_key d)
        ~root:(deferred_root ~paths d) ()
    in
    let built_target =
      match bc.role with
        | `Replica ->
            let module R = Deferred.Readable ((val plain : Deferred.S)) in
            (module R : Deferred.S)
        | _ -> plain
    in
    Hashtbl.replace built bc.name built_target;
    built_target
  in
  (* Roles are validated at parse time ({!Conf_parsing.validate_roles}), so the
     mains are empty only for a legitimately read-only domain. *)
  let composite =
    Domain_store.make
      ~mains:(List.map sub (of_roles [`Main]))
      ~targets:(List.map target (of_roles [`Replica; `Backfill]))
      ~archives:(List.map sub (of_roles [`Read_only]))
  in
  (* The only place holding each store's name, role and module at once. A store
     with no target behind it is a main or an archive, both of which reads
     reach. *)
  let members =
    List.map
      (fun ((bc : Conf_parsing.backend_config), backend) ->
        let stat f =
          Option.map
            (fun (module D : Deferred.S) () -> f (D.stats ()))
            (Hashtbl.find_opt built bc.name)
        in
        Backend.member ~name:bc.name
          ~role:(Conf_parsing.role_name bc.role)
          ~readable:
            (match Hashtbl.find_opt built bc.name with
              | Some (module D : Deferred.S) -> D.readable <> None
              | None -> true)
          ~backend_type:bc.backend_type
            (* Masked as [tsync config] does, so a report names the
                bucket without carrying a credential. *)
          ~config:
            (List.map
               (fun (k, v) ->
                 match
                   Option.bind
                     (Backend.spec_for bc.backend_type)
                     (List.find_opt (fun (s : Field_spec.t) -> s.name = k))
                 with
                   | Some { secret = true; _ } when v <> "" -> (k, "***")
                   | _ -> (k, v))
               bc.fields)
          ?pending:(stat (fun s -> s.Deferred.queued))
          ?in_flight:(stat (fun s -> s.Deferred.in_flight))
          ?degraded:(stat (fun s -> s.Deferred.degraded))
          ?traffic:
            (if Backend.counts_traffic ~backend_type:bc.backend_type then
               Hashtbl.find_opt traffic bc.name
             else None)
            (* Only a local store sits on a filesystem we can measure. *)
          ?local_path:
            (if bc.backend_type = "local" then List.assoc_opt "path" bc.fields
             else None)
          backend)
      leaves
  in
  (composite, members)

let default_domain_file ~paths =
  Filename.concat paths.Runtime.data_dir "default-domain"

(* The config says which domains exist: a name left here by a domain since
   dropped from it is ignored rather than fatal, so removing a domain does not
   break every command that omits [--domain]. *)
let default_domain ~paths =
  let configured name =
    match Conf_parsing.load paths.Runtime.config_path with
      | cfg ->
          List.exists
            (fun (d : Conf_parsing.domain) -> d.name = name)
            cfg.Conf_parsing.domains
      | exception _ -> true
  in
  match open_in (default_domain_file ~paths) with
    | ic ->
        let s = String.trim (input_line ic) in
        close_in ic;
        if s = "" || not (configured s) then None else Some s
    | exception _ -> None

(* [resume] picks up the deferred work a previous run left owed, and belongs to
   the daemon alone — a one-shot command records and drains its own, but must
   not run jobs the daemon is also running. *)
let of_config ?domain ?socket_path ?(resume = false) ~paths cfg :
    (module Conf.S) =
  let domain =
    match domain with Some _ -> domain | None -> default_domain ~paths
  in
  let d = Conf_parsing.pick_domain ?domain cfg in
  let socket_path =
    match socket_path with
      | Some p -> p
      | None -> Runtime.domain_socket_path paths d.Conf_parsing.name
  in
  (module struct
    let versioning = d.Conf_parsing.versioning
    let client_name = cfg.Conf_parsing.name
    let domain_name = d.Conf_parsing.name
    let domain_prefix = Conf_parsing.domain_prefix d
    let chunk_prefix = Conf_parsing.chunk_prefix d
    let versions_prefix = Conf_parsing.versions_prefix d
    let journal_prefix = Conf_parsing.journal_prefix d
    let cursor_key = Conf_parsing.cursor_key d
    let shares_prefix = Conf_parsing.shares_prefix d
    let store, members = build_backends ~paths ~resume d
    let cache_root = paths.Runtime.cache_root
    let data_dir = paths.Runtime.data_dir
    let socket_path = socket_path
    let max_uploads = cfg.Conf_parsing.max_uploads
    let max_chunk_buffers = cfg.Conf_parsing.max_chunk_buffers
    let max_downloads = cfg.Conf_parsing.max_downloads
    let chunk_size = d.Conf_parsing.chunk_size
    let cache_chunk_size = d.Conf_parsing.cache_chunk_size
    let max_cache = d.Conf_parsing.max_cache
    let symlink_policy = d.Conf_parsing.symlink_policy
    let read_only = d.Conf_parsing.read_only
  end : Conf.S)

(* Linux gives each domain its own socket (a domain is its own child process)
   while macOS shares one, so reaching the right daemon means resolving the
   domain first: explicit [--domain], else the persisted default, else the sole
   configured domain.

   Every command talking to a running daemon goes through this or
   {!Daemons.socket_for_path}, which is why {!Ipc.request} requires its socket
   rather than defaulting one: there is nothing to fall through to. *)
let target ?domain ~paths cfg =
  let domain =
    match domain with Some _ -> domain | None -> default_domain ~paths
  in
  let d = Conf_parsing.pick_domain ?domain cfg in
  let name = d.Conf_parsing.name in
  (name, Runtime.domain_socket_path paths name)


(* [--source] says where to read from, so only reads move: a write still goes
   through the domain's own path and reaches the deferred targets behind it.
   Raises [Failure] when nothing has that name. *)
let reading_from name (module C : Conf.S) : (module Conf.S) =
  let m =
    match
      List.filter (fun (m : Backend.member) -> m.Backend.name = name) C.members
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
               "backend name %s is ambiguous; set distinct \"name\" fields in \
                the config"
               name)
  in
  (module struct
    include C

    let store =
      (module struct
        include (val C.store : Backend.S)
        module Src = (val m.Backend.backend : Backend.S)

        let get = Src.get
        let get_opt = Src.get_opt
        let head_opt = Src.head_opt
        let list_prefix = Src.list_prefix

        (* Taken from [Src] rather than left as the composite's, which would
           read bodies through the whole domain while the listings came from
           this one store. [None] where [Src] has no batch of its own, so the
           fan-out asks the [get_opt] above. *)
        let get_many = Src.get_many
      end : Backend.S)
  end : Conf.S)
