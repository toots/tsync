let local_store ?(verify_writes = true) path =
  Backend_lwt.make ~backend_type:"local"
    ~get_field:(function
      | "verifyWrites" -> Some (string_of_bool verify_writes) | _ -> Some path)
    ()

let conf ?(domain = "testdom") ?(client_name = "test") ?(versioning = false)
    ?store:store_override ?members:members_override ?(verify_writes = true)
    ?(max_uploads = 1) ?max_chunk_buffers ?(max_downloads = 1) ?(chunk_size = 8)
    ?(cache_chunk_size = 8) ?max_cache ?(symlink_policy = `Keep)
    ?(read_only = false) ?(socket_path = "") ?cache_root ?data_dir ~root () =
  let paths =
    {
      Runtime.cache_root =
        Option.value cache_root ~default:(Filename.concat root "cache");
      data_dir = Option.value data_dir ~default:(Filename.concat root "data");
      config_path = Filename.concat root "config.json";
    }
  in
  let cfg =
    {
      Conf_parsing.name = client_name;
      tls = None;
      max_uploads;
      max_chunk_buffers = Option.value max_chunk_buffers ~default:max_uploads;
      max_downloads;
      domains =
        [
          {
            Conf_parsing.name = domain;
            backends =
              [
                {
                  Conf_parsing.backend_type = "local";
                  name = "local";
                  role = `Main;
                  fields =
                    [
                      ("path", Filename.concat root "store");
                      ("verifyWrites", string_of_bool verify_writes);
                    ];
                };
              ];
            frontends = [{ Conf_parsing.frontend_type = "fuse"; options = [] }];
            symlink_policy;
            versioning;
            read_only;
            chunk_size = Some chunk_size;
            cache_chunk_size = Some cache_chunk_size;
            max_cache;
          };
        ];
    }
  in
  let built = Domain.of_config ~domain ~socket_path ~paths cfg in
  match (store_override, members_override) with
    | None, None -> built
    | _ ->
        let module B = (val built : Conf_lwt.S) in
        (* A double has no config to be parsed from, so it is grafted onto what
           the assembly built rather than described to it. *)
        (module struct
          include B

          let store : (module Backend_lwt.Store) =
            Option.value store_override ~default:B.store

          let members : (module Backend_lwt.Store) Backend.member list =
            Option.value members_override ~default:B.members
        end : Conf_lwt.S)
