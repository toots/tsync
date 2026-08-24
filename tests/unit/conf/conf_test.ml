(* Checks read ordering by role (main, replica, readOnly, backfill — each group
   keeping config order) and that "role" is required. *)
let bc ?(role = `Main) backend_type id =
  Conf_parsing.{ backend_type; name = id; fields = [("id", id)]; role }

let ids bs =
  List.map
    (fun b -> List.assoc "id" b.Conf_parsing.fields)
    (Conf_parsing.order_backends bs)

let load json =
  Unix.putenv "TSYNC_CONFIG_JSON" json;
  Conf_parsing.load ""

let fails json = match load json with _ -> false | exception Failure _ -> true

let () =
  (* Role decides read order, not config order or backend type. *)
  assert (
    ids
      [bc ~role:`Backfill "local" "a"; bc "s3" "b"; bc ~role:`Replica "s3" "c"]
    = ["b"; "c"; "a"]);
  (* Read-only sits ahead of backfill, behind the writable ones. *)
  assert (
    ids [bc ~role:`Backfill "s3" "a"; bc ~role:`ReadOnly "s3" "b"; bc "s3" "c"]
    = ["c"; "b"; "a"]);
  (* Within a role, config order is kept. *)
  assert (ids [bc "s3" "a"; bc "s3" "b"; bc "local" "c"] = ["a"; "b"; "c"]);
  (* A single backend is unchanged. *)
  assert (ids [bc "s3" "a"] = ["a"]);

  (* "role" is required, and only the four spellings parse. *)
  let one_backend b =
    Printf.sprintf
      {|{"domains": [{"name": "d", "symlinks": "keep", "versioning": false,
                      "frontends": ["fuse"], "backends": [%s]}]}|}
      b
  in
  assert (fails (one_backend {|{"type": "s3", "name": "s"}|}));
  assert (fails (one_backend {|{"type": "s3", "name": "s", "role": "primary"}|}));

  (* A domain is writable (has a main) or purely read-only. A replica or backfill
     target with no main is a copy of nothing. *)
  let role r = Printf.sprintf {|{"type": "s3", "name": %S, "role": %S}|} r r in
  let with_backends bs = one_backend (String.concat ", " (List.map role bs)) in
  assert (fails (with_backends ["replica"]));
  assert (fails (with_backends ["backfill"]));
  assert (fails (with_backends ["replica"; "readOnly"]));
  assert (fails (with_backends ["backfill"; "readOnly"]));
  let ok bs =
    let d = List.hd (load (with_backends bs)).Conf_parsing.domains in
    List.length d.Conf_parsing.backends = List.length bs
  in
  assert (ok ["main"]);
  assert (ok ["main"; "replica"; "backfill"; "readOnly"]);
  (* One readOnly store on its own is a complete, readable domain... *)
  assert (ok ["readOnly"]);
  (* ...and it is read-only whether or not the domain says so, because no write
     could land anywhere. *)
  let read_only bs =
    (List.hd (load (with_backends bs)).Conf_parsing.domains)
      .Conf_parsing.read_only
  in
  assert (read_only ["readOnly"]);
  assert (not (read_only ["main"; "readOnly"]));
  (* Each is paired with a main, since three of the four are not a whole domain
     on their own. *)
  List.iter
    (fun r ->
      let json =
        one_backend
          (Printf.sprintf
             {|{"type": "s3", "name": "m", "role": "main"},
               {"type": "s3", "name": "s", "role": %S}|}
             (Conf_parsing.role_name r))
      in
      let d = List.hd (load json).Conf_parsing.domains in
      let b =
        List.find
          (fun (b : Conf_parsing.backend_config) -> b.name = "s")
          d.Conf_parsing.backends
      in
      assert (b.Conf_parsing.role = r);
      (* "role" is consumed, never passed on as a backend field. *)
      assert (List.assoc_opt "role" b.Conf_parsing.fields = None))
    Conf_parsing.roles;
  (* Fields reach the factory untouched whatever their JSON type: an array
     arrives re-serialized rather than dropped, so a misplaced field is never
     silently lost. *)
  Unix.putenv "TSYNC_CONFIG_JSON"
    {|{"domains": [{"name": "d", "symlinks": "keep", "versioning": false,
                    "frontends": ["fuse"],
                    "backends": [{"type": "local", "name": "l", "path": "/x",
                                  "role": "main", "count": 3, "flag": true,
                                  "list": ["a", "b"]}]}]}|};
  let cfg = Conf_parsing.load "" in
  let backend =
    List.hd (List.hd cfg.Conf_parsing.domains).Conf_parsing.backends
  in
  let field k = List.assoc k backend.Conf_parsing.fields in
  assert (field "list" = {|["a","b"]|});
  assert (field "count" = "3");
  assert (field "flag" = "true");

  (* Both frontend forms parse; a bare string is [{type}], and object keys beyond
     "type" are kept as option fields. *)
  Unix.putenv "TSYNC_CONFIG_JSON"
    {|{"domains": [{"name": "d", "symlinks": "keep", "versioning": false,
                    "frontends": ["fuse", {"type": "http", "port": "8080"}],
                    "backends": [{"type": "s3", "name": "s", "role": "main"}]}]}|};
  (match
     (List.hd (Conf_parsing.load "").Conf_parsing.domains)
       .Conf_parsing.frontends
   with
    | [a; b] ->
        assert (
          a.Conf_parsing.frontend_type = "fuse" && a.Conf_parsing.options = []);
        assert (b.Conf_parsing.frontend_type = "http");
        assert (List.assoc "port" b.Conf_parsing.options = "8080")
    | _ -> assert false);

  (* Integer and suffixed-string sizes both parse. *)
  let domain json =
    Unix.putenv "TSYNC_CONFIG_JSON" json;
    List.hd (Conf_parsing.load "").Conf_parsing.domains
  in
  let with_sizes extra =
    Printf.sprintf
      {|{"domains": [{"name": "d", "symlinks": "keep", "versioning": false,
                      %s
                      "frontends": ["fuse"],
                      "backends": [{"type": "s3", "name": "s", "role": "main"}]}]}|}
      extra
  in
  let d = domain (with_sizes {|"chunkSize": "1M", "cacheChunkSize": "64M",|}) in
  assert (d.Conf_parsing.chunk_size = Some (1024 * 1024));
  assert (d.Conf_parsing.cache_chunk_size = Some (64 * 1024 * 1024));
  let d = domain (with_sizes {|"cacheChunkSize": 4096,|}) in
  assert (d.Conf_parsing.cache_chunk_size = Some 4096);
  (* An absent size stays absent rather than resolving to a default, so
     `tsync config` shows only what the config says and a domain that does
     not care can leave both out. *)
  assert (d.Conf_parsing.chunk_size = None);
  let d = domain (with_sizes "") in
  assert (d.Conf_parsing.chunk_size = None);
  assert (d.Conf_parsing.cache_chunk_size = None);

  (* Sizes are shown to a person in exactly one spelling — [Metrics.human_bytes]
     — and [configure] offers that spelling back as a prompt default, so
     whatever it prints has to parse. Checked here because it is the one
     contract that spans the two modules. *)
  let k = 1024 in
  List.iter
    (fun n -> assert (Conf_parsing.parse_size (Metrics.human_bytes n) = Some n))
    [512; 8 * k; 512 * k; 8 * k * k; 3 * k * k * k; 2 * k * k * k * k];
  (* The spellings a person may type by hand, all still accepted. *)
  assert (Conf_parsing.parse_size "8M" = Some (8 * k * k));
  assert (Conf_parsing.parse_size "8mib" = Some (8 * k * k));
  assert (Conf_parsing.parse_size "8388608" = Some (8 * k * k));
  assert (Conf_parsing.parse_size "0.5 GB" = Some (512 * k * k));
  (* Not a size: rejected rather than silently read as some number of bytes. *)
  assert (Conf_parsing.parse_size "" = None);
  assert (Conf_parsing.parse_size "lots" = None);
  assert (Conf_parsing.parse_size "-4M" = None);
  assert (Conf_parsing.parse_size "0" = None);
  assert (Conf_parsing.parse_size "inf" = None);

  (* [maxChunkBuffers] follows [maxUploads] unless it is set, so a config
     written before the two were separable keeps its memory ceiling. *)
  let globals extra =
    Printf.sprintf
      {|{%s "domains": [{"name": "d", "symlinks": "keep", "versioning": false,
                         "frontends": ["fuse"],
                         "backends": [{"type": "s3", "name": "s",
                                       "role": "main"}]}]}|}
      extra
  in
  let buffers extra = (load (globals extra)).Conf_parsing.max_chunk_buffers in
  assert (buffers "" = Conf_parsing.default_max_uploads);
  assert (buffers {|"maxUploads": 16,|} = 16);
  assert (buffers {|"maxUploads": 16, "maxChunkBuffers": 4,|} = 4);
  (* Zero would deadlock the pool, so it falls back rather than being taken. *)
  assert (buffers {|"maxUploads": 16, "maxChunkBuffers": 0,|} = 16);

  (* Where a domain shows up in the filesystem, which is what turns a path a
     user typed into a domain and a path within it. The configured mount comes
     first, so it wins over the data dir every domain shares. *)
  let mounted at =
    Printf.sprintf
      {|{"domains": [{"name": "d", "symlinks": "keep", "versioning": false,
                      "frontends": [{"type": "fuse", "mountPoint": "%s"}],
                      "backends": [{"type": "s3", "name": "s",
                                    "role": "main"}]}]}|}
      at
  in
  let roots at =
    Conf_parsing.roots_of ~data_dir:"/var/tsync"
      (List.hd (load (mounted at)).Conf_parsing.domains)
  in
  assert (List.hd (roots "/mnt/d") = "/mnt/d");
  assert (List.mem "/var/tsync" (roots "/mnt/d"));
  (* Unset, the mount is the default one rather than absent, or a path under it
     would name no domain. *)
  assert (List.hd (roots "") = Filename.concat (Sys.getenv "HOME") "tsync/d");

  (* The room a write has. Only a store on a disk can say, so a domain of
     stores that cannot answers nothing rather than a number, and a caller says
     for itself what to report then. *)
  let store ?local_path ?(role = `Main) name =
    Backend.member ~name ~role ?local_path
      (Backend.make ~backend_type:"local"
         ~get_field:(fun _ -> Some (Filename.get_temp_dir_name ()))
         ())
  in
  assert (Conf.capacity [] = None);
  assert (Conf.capacity [store "remote"] = None);
  let here = Filename.get_temp_dir_name () in
  assert (Conf.capacity [store ~local_path:here "disk"] <> None);
  (* A store never written to does not bound a write. *)
  assert (Conf.capacity [store ~local_path:here ~role:`ReadOnly "cold"] = None);
  (* The tightest of them, and one store's figures rather than a per-field
     minimum. *)
    (match
       Conf.capacity [store ~local_path:here "a"; store ~local_path:here "b"]
     with
    | Some { Fs_util.avail; total; _ } -> assert (avail <= total)
    | None -> assert false);

  Unix.putenv "TSYNC_CONFIG_JSON" "";
  print_endline "conf_test ok"
