type stats = {
  versions_deleted : int;
  chunks_deleted : int;
  chunks_kept : int;
}

module Make (C : Conf.S) = struct
  let primary () =
    match C.backends with b :: _ -> b | [] -> failwith "no backends configured"

  let delete_all keys =
    if keys <> [] then
      List.iter (fun (module B : Backend.S) -> B.delete_multi keys) C.backends

  let is_marker key =
    String.length key > 0 && key.[String.length key - 1] = '/'

  (* Chunk keys referenced by the manifest stored at [key]. Directory markers
     reference nothing; a dirty manifest is mid-write and has no committed
     chunks. An unexpected parse failure aborts (raises) rather than reporting
     "references nothing", which would let the sweep delete the file's chunks. *)
  let referenced_chunks (module B : Backend.S) key =
    if is_marker key then []
    else
      match Manifest.of_string (B.get ~key ()) with
        | `Clean m -> List.map Manifest.chunk_key m.Manifest.chunks
        | `Dirty -> []
        | exception e ->
            failwith
              (Printf.sprintf
                 "cannot read manifest %s (%s); aborting before chunk GC" key
                 (Printexc.to_string e))

  let parse = Versioning.parse ~versions_prefix:C.versions_prefix

  let expire ~cutoff () =
    let (module B : Backend.S) = primary () in
    let cutoff_ns = Int64.of_float (cutoff *. 1e9) in
    (* Phase 1: partition versions by the cutoff (no deletion yet). *)
    let expired, surviving =
      B.list_all ~prefix:C.versions_prefix ()
      |> List.fold_left
           (fun (expired, surviving) (e : Backend.file_entry) ->
             match parse e.key with
               | Some (rel, ts)
                 when Int64.compare (Int64.of_string ts) cutoff_ns < 0 ->
                   ((e.key, rel) :: expired, surviving)
               | Some (rel, _) -> (expired, (e.key, rel) :: surviving)
               | None -> (expired, surviving))
           ([], [])
    in
    (* Phase 2: mark chunks referenced by live files and surviving versions.
       Done before any deletion so a bad manifest aborts with nothing removed.
       ponytail: GET per manifest — no chunk refcount index; add one only if a
       scan measurably hurts. *)
    let live = Hashtbl.create 4096 in
    let mark key =
      List.iter
        (fun ck -> Hashtbl.replace live ck ())
        (referenced_chunks (module B) key)
    in
    List.iter
      (fun (e : Backend.file_entry) -> mark e.key)
      (B.list_all ~prefix:C.domain_prefix ());
    List.iter (fun (key, _rel) -> mark key) surviving;
    (* Phase 3: delete expired versions, then the version directories they
       emptied. On S3 no directory object exists, so those deletes are harmless
       no-ops; on a filesystem backend they prune the now-empty directory. *)
    delete_all (List.map fst expired);
    let survivor_rels = List.map snd surviving in
    List.sort_uniq compare (List.map snd expired)
    |> List.filter (fun rel -> not (List.mem rel survivor_rels))
    |> List.map (fun rel -> C.versions_prefix ^ rel ^ "/")
    |> delete_all;
    (* Phase 4: sweep every chunk not referenced anywhere, regardless of age. *)
    let kept = ref 0 in
    let unreferenced =
      B.list_all ~prefix:C.chunk_prefix ()
      |> List.filter_map (fun (e : Backend.file_entry) ->
             let ck =
               String.sub e.key
                 (String.length C.chunk_prefix)
                 (String.length e.key - String.length C.chunk_prefix)
             in
             if Hashtbl.mem live ck then (
               incr kept;
               None)
             else Some e.key)
    in
    delete_all unreferenced;
    {
      versions_deleted = List.length expired;
      chunks_deleted = List.length unreferenced;
      chunks_kept = !kept;
    }
end
