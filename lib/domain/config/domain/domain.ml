(* Every store's writes join the process governor's line; a ceiling in the
   config is this store's own gate in front of it, one per store built. *)
let make_backend ~traffic ~admission (bc : Conf_parsing.backend_config) =
  Backend_lwt.make ~admission ~traffic ~backend_type:bc.backend_type
    ~get_field:(fun k -> List.assoc_opt k bc.fields)
    ()

(* One small round trip the governor may time: a head of the domain cursor,
   which every written store holds and which costs nothing to ask about. A
   store that is a tree here has no link to measure; one held down is left to
   its own retry loop. *)
let attach_probe ~cursor_key (bc : Conf_parsing.backend_config) store =
  let module St = (val store : Backend_lwt.Store) in
  if St.local_path = None then
    let module U = Tsync_core_lwt.Uplink_lwt in
    U.attach (U.process ()) ~name:bc.Conf_parsing.name
      ~held:(fun () -> Health.is_held St.health)
      ~probe:(fun () -> Lwt.map ignore (St.head_opt ~key:cursor_key ()))

let admission_for (_ : Conf_parsing.backend_config) =
  let module U = Tsync_core_lwt.Uplink_lwt in
  U.admission (U.process ()) U.Background

(* Empty for a body that is not a manifest: a folder marker, a trash marker, a
   share. *)
let chunk_keys data =
  match Manifest.of_string data with
    | t -> List.init (Manifest.count t) (Manifest.key t)
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
let build_backends ~paths ~resume ~max_chunk_forwards
    (d : Conf_parsing.domain) :
    (module Backend_lwt.Store) * (module Backend_lwt.Store) Backend.member list
    =
  (* One counter pair per configured store, kept by name so the member built
     below reports the very counters that store's wrapper adds to. *)
  let traffic : (string, Backend.traffic) Hashtbl.t = Hashtbl.create 4 in
  (* Kept by name beside the counters: a deferred target asks its own store's
     gate whether a forward may go, the same gate the write then takes. *)
  let admissions = Hashtbl.create 4 in
  (* Shared by every layer below: a second [make_backend] for the same config is
     a second client against the same store. Order comes from
     {!Conf_parsing.order_backends}, so a main answers first. *)
  let leaves =
    List.map
      (fun (bc : Conf_parsing.backend_config) ->
        let t = Backend.new_traffic () in
        Hashtbl.replace traffic bc.Conf_parsing.name t;
        let admission = admission_for bc in
        Hashtbl.replace admissions bc.Conf_parsing.name admission;
        let store = make_backend ~traffic:t ~admission bc in
        attach_probe ~cursor_key:(Conf_parsing.cursor_key d) bc store;
        (bc, store))
      (Conf_parsing.order_backends d.Conf_parsing.backends)
  in
  let of_roles rs =
    List.filter
      (fun ((bc : Conf_parsing.backend_config), _) -> List.mem bc.role rs)
      leaves
  in
  let sub ((bc : Conf_parsing.backend_config), backend) =
    { Domain_store_lwt.name = bc.Conf_parsing.name; backend }
  in
  (* Kept so [report_members] and the share list can ask a target how it is
     doing, and whether reads reach it, without re-deriving either from the
     role. *)
  let built : (string, (module Domain_store_lwt.Deferred.S)) Hashtbl.t =
    Hashtbl.create 4
  in
  let target ((bc : Conf_parsing.backend_config), backend) ~source =
    let built_target =
      Domain_store_lwt.Deferred.make ~resume ~max_chunk_forwards
        ~room_for:(Hashtbl.find admissions bc.name).Uplink.try_admit
        ~name:bc.name ~backend ~source
        ~chunk_prefix:(Conf_parsing.chunk_prefix d)
        ~chunk_from_prefix:
          (let module L = Chunk_layout.Make (struct
             let chunk_prefix = Conf_parsing.chunk_prefix d
           end) in
          L.from_prefix)
        ~chunk_keys
        ~journal_prefix:(Conf_parsing.journal_prefix d)
        ~cursor_key:(Conf_parsing.cursor_key d)
        ~excluded:Stored_key.is_index_key ~reads_reach:(bc.role = `Replica)
        ~root:(deferred_root ~paths d) ()
    in
    Hashtbl.replace built bc.name built_target;
    built_target
  in
  (* Roles are validated at parse time ({!Conf_parsing.validate_roles}), so the
     mains are empty only for a legitimately read-only domain. *)
  let composite =
    Domain_store_lwt.make
      ~mains:(List.map sub (of_roles [`Main]))
      ~targets:(List.map target (of_roles [`Replica; `Backfill]))
      ~archives:(List.map sub (of_roles [`ReadOnly]))
  in
  (* The only place holding each store's name, role and module at once. A store
     with no target behind it is a main or an archive, both of which reads
     reach. *)
  let members =
    List.map
      (fun ((bc : Conf_parsing.backend_config), backend) ->
        let stat f =
          Option.map
            (fun (module D : Domain_store_lwt.Deferred.S) () -> f (D.stats ()))
            (Hashtbl.find_opt built bc.name)
        in
        Backend.member ~name:bc.name ~role:bc.role
          ~readable:
            (match Hashtbl.find_opt built bc.name with
              | Some (module D : Domain_store_lwt.Deferred.S) ->
                  D.readable <> None
              | None -> true)
          ~backend_type:bc.backend_type
            (* Masked as [tsync config] does, so a report names the
                bucket without carrying a credential. *)
          ~config:
            (List.map
               (fun (k, v) ->
                 ( k,
                   Field_spec.mask_named
                     (Option.value ~default:[]
                        (Backend_lwt.spec_for bc.backend_type))
                     k v ))
               bc.fields
            (* Appended rather than prepended: a report names a store by the
               first config entry that says anything, which should stay the
               bucket or the path. *)
            @
            if bc.Conf_parsing.link = Conf_parsing.default_link then []
            else [("link", bc.Conf_parsing.link)])
          ?pending:(stat (fun s -> s.Deferred.queued))
          ?in_flight:(stat (fun s -> s.Deferred.in_flight))
          ?degraded:(stat (fun s -> s.Deferred.degraded))
          ?traffic:
            (let module B = (val backend : Backend_lwt.Store) in
            if B.local_path = None then Hashtbl.find_opt traffic bc.name
            else None)
            (* Both of these are the store's own, not config's to work out from
               its type: where it keeps its files, and so whether anything it
               moved crossed a link. *)
          ?local_path:
            (let module B = (val backend : Backend_lwt.Store) in
            B.local_path)
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
    (module Conf_lwt.S) =
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

    (* Before the first store is built, which joins the governor's line; a
       second domain in the same process finds it configured and leaves it. *)
    let () = Tsync_core_lwt.Uplink_lwt.configure cfg.Conf_parsing.uplink

    (* A forward holds a chunk body past the buffer that carried it, so the
       buffers' budget is the ceiling on forwards too. *)
    let store, members =
      build_backends ~paths ~resume
        ~max_chunk_forwards:cfg.Conf_parsing.max_chunk_buffers d
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

    include Conf_lwt.Monad
  end : Conf_lwt.S)

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

let socket ?domain ~paths cfg = snd (target ?domain ~paths cfg)

let reading_at_most n (module C : Conf_lwt.S) : (module Conf_lwt.S) =
  if n < 1 then failwith "at least one read at a time";
  (module struct
    include C

    let max_downloads = n
  end)

(* [--source] says where to read from, so only reads move: a write still goes
   through the domain's own path and reaches the deferred targets behind it.
   Raises [Failure] when nothing has that name. *)
let reading_from name (module C : Conf_lwt.S) : (module Conf_lwt.S) =
  let m = Backend.named_exn name C.members in
  (module struct
    include C

    let store =
      (module struct
        include (val C.store : C.Store)
        module Src = (val m.Backend.backend : C.Store)

        let get = Src.get
        let get_opt = Src.get_opt
        let get_range = Src.get_range
        let fast_read = Src.fast_read
        let head_opt = Src.head_opt
        let list_prefix = Src.list_prefix

        (* With the reads, for the same reason: a wake from a store this does
           not read from says nothing about the one it does. *)
        let watch = Src.watch

        (* Taken from [Src] rather than left as the composite's, which would
           read bodies through the whole domain while the listings came from
           this one store. [None] where [Src] has no batch of its own, so the
           fan-out asks the [get_opt] above. *)
        let get_many = Src.get_many
        let list_many = Src.list_many

        (* With them too: every read served here goes to [Src], so the
           composite's "a domain is not a member, never held" would be a report
           about a store this one does not ask. *)
        let health = Src.health
      end : Backend_lwt.Store)
  end : Conf_lwt.S)
