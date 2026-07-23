(* Tiered composite backend:
   - backfill shape: chunk reads are first-available (preferred -> source) and served
     chunks backfill the incomplete backend; manifests/listings come from the
     non-backfill source only; writes fan out.
   - readOnly shape: when the primary is unreachable, reads fall back to a read-only
     authoritative backend, but writes never reach it (and fail when the only
     writable backend is down). *)

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

(* A backend that is "down": every operation raises. Reads should fall through it;
   a write that reaches it must fail. *)
module Down : Backend.S = struct
  let fail () = Lwt.fail (Backend.Backend_error "down")
  let put ~key:_ ~data:_ () = fail ()
  let get ~key:_ () = fail ()
  let get_opt ~key:_ () = fail ()
  let head_opt ~key:_ () = fail ()
  let delete ~key:_ () = fail ()
  let delete_multi _ = fail ()
  let copy ~src_key:_ ~dst_key:_ () = fail ()
  let list_all ?max_keys:_ ~prefix:_ () = fail ()
  let list_directory ~prefix:_ () = fail ()
  let share_url ~prefix:_ () = Lwt.return_none
end

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
  (* Backfill shape: cache is main + backfill target, source is the non-backfill
     source of truth. *)
  let (module T : Backend.S) =
    Tiered_backend.make ~chunk_prefix:"tsync/d/chunks/"
      ~read_order:[sub "cache" cache; sub "source" source]
      ~manifest_read:[sub "source" source]
      ~writes:[cache; source]
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

     (* readOnly shape: primary "proxy" is down, source is a read-only fallback. *)
     let (module R : Backend.S) =
       Tiered_backend.make ~chunk_prefix:"tsync/d/chunks/"
         ~read_order:[sub "proxy" (module Down); sub "s3" source]
         ~manifest_read:[sub "proxy" (module Down); sub "s3" source]
         ~writes:[(module Down)] (* s3 is read-only -> excluded from writes *)
         ~backfills:[]
     in
     (* chunk read falls through the down primary to the fallback *)
     let* c = R.get ~key:ckey () in
     assert (c = "chunkdata");
     (* manifest read falls through too *)
     let* m = R.get ~key:mkey () in
     assert (m = "manifestdata");
     (* listing falls through *)
     let* files, _ = R.list_directory ~prefix:"tsync/d/chunks/" () in
     assert (List.exists (fun (e : Backend.file_entry) -> e.key = ckey) files);
     (* a write hits only the (down) primary and fails; the read-only backend is
        never written *)
     let* write_failed =
       Lwt.catch
         (fun () ->
           let* () = R.put ~key:"tsync/d/chunks/ro" ~data:"x" () in
           Lwt.return_false)
         (fun _ -> Lwt.return_true)
     in
     assert write_failed;
     assert (not (Sys.file_exists (source_dir ^ "/tsync/d/chunks/ro")));

     print_endline "tiered_test ok";
     Lwt.return_unit)
