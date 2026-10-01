open Tsync_core
open Tsync_checkout
open Tsync_remote

module Make (C : Engine_ctx.S) = struct
  include Outbound.Make (C)

  (* durable-queue §7.3: the batch's record lists its Puts before any of them
     is put, and is held until they ran; files a batch did not reach go to
     the next one. *)
  let import ?(narrate = Narrate.none) ?(cancelled = Fun.const false)
      ?(only = []) ?(exclude = []) ?(force_rehash = false) src =
    (* 05 §4.2 ENTRY_OPS / ENTRY_AGE. *)
    let entry_ops = 2000 in
    let entry_age = 10. in
    let exists rel = kind rel <> `Absent || store_manifest rel <> None in
    let install rel m =
      let pid = ensure_folder_id (Names.parent_of rel) in
      let leaf = Names.leaf_of rel in
      m (fun ?resend m ->
          R.publish ?resend ~parent:pid ~leaf m;
          let m = Manifest.rename m leaf in
          with_meta (fun () ->
              with_key rel (fun () -> Mirror.write_file ~own:true mirror rel m)))
    in
    let upload_file rel path =
      let st = Unix.stat path in
      let size = st.st_size and cs = R.chunk_size () in
      Fs.with_fd (Fs.openfile path [O_RDONLY]) (fun fd ->
          let read i =
            let len = if size = 0 then 0 else Chunking.length ~size ~cs i in
            let buf = Bigstring.create len in
            let n = Fs.pread_full fd buf ~boff:0 ~len ~off:(i * cs) in
            Bigstring.sub buf ~off:0 ~len:n
          in
          let m =
            R.upload_chunks ~name:(Names.leaf_of rel) ~size ~chunk_size:cs
              ~mtime:st.st_mtime (fun i -> Remote.Lazy (fun () -> read i))
          in
          let resend ck =
            let rec find i =
              if i >= m.count then None
              else if Chunk_key.equal (Manifest.key m i) ck then Some (read i)
              else find (i + 1)
            in
            find 0
          in
          install rel (fun publish -> publish ~resend m);
          size)
    in
    let import_one (e : Import_plan.entry) : Import_plan.outcome =
      match e with
        | Folder _ -> Skipped_exists
        | File { rel; path; _ } -> Imported (upload_file rel path)
        | Link { rel; path; target; _ } -> (
            match C.symlinks with
              | `Skip -> Skipped_symlink
              | `Keep ->
                  let mtime = (Unix.lstat path).st_mtime in
                  install rel (fun publish ->
                      publish
                        (Manifest.symlink ~name:(Names.leaf_of rel) ~mtime
                           target));
                  Imported 0
              | `Follow -> (
                  match Unix.stat path with
                    | { st_kind = S_REG; _ } -> Imported (upload_file rel path)
                    | _ | (exception Unix.Unix_error _) -> Skipped_symlink))
    in
    (* A folder this client holds no id for is claimed now, so the files beneath
       can be published, and announced through the ordered metadata queue. *)
    let plan_folder rel =
      match Mirror.kind mirror rel with
        | `File -> Error "a file holds this name in the domain"
        | `Dir when Mirror.folder_id mirror rel <> None -> Ok false
        | _ ->
            let id = ensure_folder_id rel in
            with_meta (fun () ->
                record_owed [Op.Mkdir { path = rel; id = Some id }] ignore);
            Ok true
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
          match plan_folder rel with
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
      List.exists (fun b -> String.starts_with ~prefix:(b ^ "/") rel) !blocked
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
    let rec batches = function
      | [] -> ()
      | _ when cancelled () -> ()
      | todo ->
          let rec choose n acc = function
            | e :: rest when n < entry_ops ->
                let rel = rel_of e in
                if under_blocked rel then (
                  note e (Failed "its folder could not be created");
                  choose n acc rest)
                else if (not force_rehash) && exists rel then (
                  note e Skipped_exists;
                  choose n acc rest)
                else choose (n + 1) (e :: acc) rest
            | rest -> (List.rev acc, rest)
          in
          let chosen, rest = choose 0 [] todo in
          if chosen <> [] then (
            let ops =
              List.map
                (fun e ->
                  Op.Put { path = rel_of e; size = size_of e; base = None })
                chosen
            in
            let id, fd =
              Dqueue.Records.create_held ~mint wal
                (Wal.encode
                   {
                     Wal.state = Prepared;
                     attempts = 0;
                     ops;
                     priors = [];
                     local_from = [];
                     last_error = None;
                   })
            in
            let started = Unix.gettimeofday () in
            let rec run = function
              | [] -> []
              | left
                when cancelled () || Unix.gettimeofday () -. started > entry_age
                ->
                  left
              | e :: rest ->
                  Narrate.progress narrate
                    ~fraction:(float !seen_bytes /. float (max 1 plan.bytes))
                    "importing %d of %d files (%s of %s): %s"
                    (!imported + !skipped + !skipped_links + List.length !failed
                   + 1)
                    plan.files (Narrate.size !seen_bytes)
                    (Narrate.size plan.bytes) (rel_of e);
                  note e
                    (try import_one e with
                      | (Stop.Stopping | Rt.Cancelled) as x -> raise x
                      | x -> Failed (Printexc.to_string x));
                  run rest
            in
            let left =
              Fun.protect
                ~finally:(fun () ->
                  Unix.close fd;
                  Dqueue.adopt uploads id)
                (fun () -> run chosen)
            in
            Narrate.say narrate "  announced a batch of %s"
              (Narrate.count (List.length chosen - List.length left) "file");
            batches (left @ rest))
          else batches rest
    in
    batches items;
    {
      Import_plan.imported = !imported;
      bytes = !bytes;
      skipped = !skipped;
      skipped_symlinks = !skipped_links;
      failed = List.rev !failed;
      cancelled = cancelled ();
    }
end
