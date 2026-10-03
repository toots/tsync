open Tsync_core

module Make (C : Engine_ctx.S) = struct
  include Bulk.Make (C)

  let import ?(narrate = Narrate.none) ?(cancelled = Fun.const false)
      ?(only = []) ?(exclude = []) ?(force_rehash = false) src =
    let import_one (e : Import_plan.entry) : Import_plan.outcome =
      match e with
        | Folder _ -> Skipped_exists
        | File { rel; path; _ } -> Imported (Bulk.upload_file rel path)
        | Link { rel; path; target; _ } -> (
            match C.symlinks with
              | `Skip -> Skipped_symlink
              | `Keep ->
                  Bulk.publish_link rel ~target
                    ~mtime:(Unix.lstat path).st_mtime;
                  Imported 0
              | `Follow -> (
                  match Unix.stat path with
                    | { st_kind = S_REG; _ } ->
                        Imported (Bulk.upload_file rel path)
                    | _ | (exception Unix.Unix_error _) -> Skipped_symlink))
    in
    let rel_of = function
      | Import_plan.Folder r -> r
      | File { rel; _ } | Link { rel; _ } -> rel
    in
    let size_of = function
      | Import_plan.Folder _ -> 0
      | File { size; _ } | Link { size; _ } -> size
    in
    let plan = Import_plan.plan ~only ~exclude ~symlinks:C.symlinks src in
    Narrate.say narrate "planned %s (%s) from %s"
      (Narrate.count plan.files "file")
      (Narrate.size plan.bytes) src;
    List.iter
      (fun d -> Narrate.say narrate "  could not list %s; counted as empty" d)
      plan.unreadable;
    let folders, items =
      List.partition
        (function Import_plan.Folder _ -> true | _ -> false)
        plan.entries
    in
    let blocked = ref [] in
    let created = ref 0 in
    List.iter
      (fun e ->
        if not (cancelled ()) then (
          let rel = rel_of e in
          Narrate.progress narrate "creating folders: %s" rel;
          match Bulk.folder rel with
            | Ok true -> incr created
            | Ok false -> ()
            | Error reason ->
                Narrate.say narrate "  %s: %s; nothing beneath it is imported"
                  rel reason;
                blocked := rel :: !blocked))
      folders;
    Narrate.say narrate "  %s created and announced"
      (Narrate.count !created "folder");
    let under_blocked rel =
      List.exists (fun dir -> Names.is_under ~dir rel) !blocked
    in
    let imported = ref 0 and bytes = ref 0 and skipped = ref 0 in
    let skipped_links = ref 0 and failed = ref [] in
    let seen_bytes = ref 0 in
    let note e (o : Import_plan.outcome) =
      seen_bytes := !seen_bytes + size_of e;
      match o with
        | Imported n ->
            incr imported;
            bytes := !bytes + n
        | Skipped_exists -> incr skipped
        | Skipped_symlink -> incr skipped_links
        | Failed reason ->
            Narrate.say narrate "  %s failed: %s" (rel_of e) reason;
            failed := (rel_of e, reason) :: !failed
    in
    let admit e =
      let rel = rel_of e in
      if under_blocked rel then (
        note e (Failed "its folder could not be created");
        false)
      else if (not force_rehash) && Bulk.exists rel then (
        note e Skipped_exists;
        false)
      else true
    in
    let run e =
      Narrate.progress narrate
        ~fraction:(float !seen_bytes /. float (max 1 plan.bytes))
        "importing %d of %d files (%s of %s): %s"
        (!imported + !skipped + !skipped_links + List.length !failed + 1)
        plan.files (Narrate.size !seen_bytes) (Narrate.size plan.bytes)
        (rel_of e);
      let outcome =
        try import_one e with
          | (Stop.Stopping | Rt.Cancelled) as x -> raise x
          | x -> Failed (Printexc.to_string x)
      in
      note e outcome;
      match outcome with Imported _ -> true | _ -> false
    in
    Bulk.batches ~narrate ~noun:"file" ~cancelled ~queue:uploads
      ~op:(fun e -> Op.Put { path = rel_of e; size = size_of e; base = None })
      ~admit ~run items;
    {
      Import_plan.imported = !imported;
      bytes = !bytes;
      skipped = !skipped;
      skipped_symlinks = !skipped_links;
      failed = List.rev !failed;
      cancelled = cancelled ();
    }
end
