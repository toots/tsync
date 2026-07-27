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
  (* role decides read order, not config order or backend type *)
  assert (
    ids
      [bc ~role:`Backfill "local" "a"; bc "s3" "b"; bc ~role:`Replica "s3" "c"]
    = ["b"; "c"; "a"]);
  (* read-only sits ahead of backfill, behind the writable ones *)
  assert (
    ids [bc ~role:`Backfill "s3" "a"; bc ~role:`Read_only "s3" "b"; bc "s3" "c"]
    = ["c"; "b"; "a"]);
  (* within a role, config order is kept *)
  assert (ids [bc "s3" "a"; bc "s3" "b"; bc "local" "c"] = ["a"; "b"; "c"]);
  (* single backend is unchanged *)
  assert (ids [bc "s3" "a"] = ["a"]);

  (* "role" is required, and only the four spellings parse *)
  let one_backend b =
    Printf.sprintf
      {|{"domains": [{"name": "d", "symlinks": "keep", "versioning": false,
                      "frontends": ["fuse"], "backends": [%s]}]}|}
      b
  in
  assert (fails (one_backend {|{"type": "s3", "name": "s"}|}));
  assert (fails (one_backend {|{"type": "s3", "name": "s", "role": "primary"}|}));

  (* A domain is writable (has a main) or purely read-only (readOnly stores
     alone). A replica or backfill target with no main is a copy of nothing, and
     a domain nothing can answer a read from is unusable. *)
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
  (* Every spelling parses. Each is paired with a main, since three of the four
     are not a whole domain on their own — see the role coherence rules below. *)
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
      (* "role" is consumed, never passed on as a backend field *)
      assert (List.assoc_opt "role" b.Conf_parsing.fields = None))
    Conf_parsing.roles;
  (* Backend fields are handed to the factory untouched, whatever their JSON
     type. An array arrives re-serialized rather than being dropped, so a backend
     that wants a list gets one and a misplaced field is never silently lost. *)
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

  (* frontends: bare string and object forms both parse; string = {type};
     object keys beyond "type" are kept as option fields *)
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

  (* sizes: integer and suffixed-string spellings both parse *)
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
  (* An absent size stays absent rather than being resolved to a default here:
     that is what lets `tsync print-config` show only what the config says, and
     what lets a domain that does not care (the FileProvider hands over whole
     files, so it barely reads through the chunk cache) leave both out. *)
  assert (d.Conf_parsing.chunk_size = None);
  let d = domain (with_sizes "") in
  assert (d.Conf_parsing.chunk_size = None);
  assert (d.Conf_parsing.cache_chunk_size = None);

  Unix.putenv "TSYNC_CONFIG_JSON" "";
  print_endline "conf_test ok"
