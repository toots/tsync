let local_store ?(verify_writes = true) path =
  Backend.make ~backend_type:"local"
    ~get_field:(function
      | "verifyWrites" -> Some (string_of_bool verify_writes) | _ -> Some path)
    ()

let conf ?(domain = "testdom") ?(client_name = "test") ?(versioning = false)
    ?store ?members ?(verify_writes = true) ?(max_uploads = 1)
    ?max_chunk_buffers ?(max_downloads = 1) ?(chunk_size = 8)
    ?(cache_chunk_size = 8) ?max_cache ?(symlink_policy = `Keep)
    ?(read_only = false) ?(socket_path = "") ?cache_root ?data_dir ~root () =
  let the_store =
    match store with
      | Some s -> s
      | None -> local_store ~verify_writes (Filename.concat root "store")
  in
  (module struct
    let versioning = versioning
    let client_name = client_name
    let domain_name = domain
    let domain_prefix = "tsync/" ^ domain ^ "/manifests/"
    let chunk_prefix = "tsync/" ^ domain ^ "/chunks/"
    let versions_prefix = "tsync/" ^ domain ^ "/versions/"
    let journal_prefix = "tsync/" ^ domain ^ "/journal/"
    let cursor_key = "tsync/" ^ domain ^ "/cursor"
    let shares_prefix = "tsync/shares/"
    let store = the_store

    let members =
      match members with
        | Some m -> m
        | None -> [Backend.member ~name:"local" the_store]

    let cache_root =
      Option.value cache_root ~default:(Filename.concat root "cache")

    let data_dir = Option.value data_dir ~default:(Filename.concat root "data")
    let socket_path = socket_path
    let max_uploads = max_uploads

    (* As the real config does: only a host short on memory relative to its
       chunk size sets this apart from [max_uploads]. *)
    let max_chunk_buffers = Option.value max_chunk_buffers ~default:max_uploads
    let max_downloads = max_downloads
    let chunk_size = Some chunk_size
    let cache_chunk_size = Some cache_chunk_size
    let max_cache = max_cache
    let symlink_policy = symlink_policy
    let read_only = read_only
  end : Conf.S)
