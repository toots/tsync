(* Tiered composite backend: chunk reads are first-available (preferred -> source)
   and served chunks backfill the incomplete backend; manifests/listings come from
   the source of truth only; writes fan out. *)

let root = "/tmp/tsync-tiered-test"
let source_dir = root ^ "/source"
let cache_dir = root ^ "/cache"

let write path data =
  ignore
    (Sys.command
       (Printf.sprintf "mkdir -p %s" (Filename.quote (Filename.dirname path))));
  let oc = open_out path in
  output_string oc data;
  close_out oc

let () =
  ignore
    (Sys.command
       (Printf.sprintf "rm -rf %s && mkdir -p %s %s" root source_dir cache_dir));
  let ckey = "tsync/d/chunks/abc" and mkey = "tsync/d/manifests/x" in
  (* source of truth has the chunk and the manifest; cache starts empty *)
  write (source_dir ^ "/" ^ ckey) "chunkdata";
  write (source_dir ^ "/" ^ mkey) "manifestdata";
  let source = Local_backend.make ~root:source_dir in
  let cache = Local_backend.make ~root:cache_dir in
  let sub name backend = { Tiered_backend.name; backend } in
  (* Romain's shape: cache is main + backfill target, source is source of truth. *)
  let read_order = [sub "cache" cache; sub "source" source] in
  let (module T : Backend.S) =
    Tiered_backend.make ~chunk_prefix:"tsync/d/chunks/" ~source ~read_order
      ~backfills:[sub "cache" cache]
  in
  Lwt_main.run
    (let open Lwt.Syntax in
     (* chunk: cache miss -> served from source *)
     let* c = T.get ~key:ckey () in
     assert (c = "chunkdata");
     (* manifest: from source, never backfilled *)
     let* m = T.get ~key:mkey () in
     assert (m = "manifestdata");
     (* let the async, bounded backfill settle *)
     let* () = Lwt_unix.sleep 0.3 in
     assert (Sys.file_exists (cache_dir ^ "/" ^ ckey));
     (* the chunk was mirrored into cache *)
     assert (not (Sys.file_exists (cache_dir ^ "/" ^ mkey)));
     (* the manifest was NOT *)
     (* second read is a cache hit, and must not re-backfill (dedup) — just works *)
     let* c2 = T.get ~key:ckey () in
     assert (c2 = "chunkdata");
     (* put fans out to both backends *)
     let* () = T.put ~key:"tsync/d/chunks/new" ~data:"newdata" () in
     assert (Sys.file_exists (source_dir ^ "/tsync/d/chunks/new"));
     assert (Sys.file_exists (cache_dir ^ "/tsync/d/chunks/new"));
     (* listing comes from the source of truth *)
     let* files, _ = T.list_directory ~prefix:"tsync/d/chunks/" () in
     let names = List.map (fun (e : Backend.file_entry) -> e.key) files in
     assert (List.mem ckey names);
     (* a missing chunk is None everywhere *)
     let* none = T.get_opt ~key:"tsync/d/chunks/nope" () in
     assert (none = None);
     print_endline "tiered_test ok";
     Lwt.return_unit)
