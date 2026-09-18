type outcome =
  [ `Exported | `Exported_symlink | `Already_there | `Failed of string ]

type planned = { files : int; bytes : int64; present : int64 }
type started = { rel : string; size : int64; present : int64 }

type event =
  [ `Plan of planned
  | `Started of started
  | `Landed of string * int
  | `Finished of string * outcome ]

type summary = {
  exported : int;
  already_there : int;
  failed : int;
  pending : string list;
}

module Record = struct
  type identity = {
    h1 : string;
    h2 : string;
    size : int64;
    chunk_size : int;
    dst : string;
  }

  (* Compared whole rather than parsed, so there is no field a reader could
     take from a record that is not this file's. *)
  let header id =
    Printf.sprintf "tsync-export 1 %s %s %Ld %d %s\n" id.h1 id.h2 id.size
      id.chunk_size (String.escaped id.dst)

  let claim i = string_of_int i ^ "\n"

  (* A line that is not an index in range is where a crash tore the file, and
     everything before it was written whole. *)
  let claimed_of_lines ~count lines =
    let claimed = Bytes.make count '\000' in
    let rec go = function
      | [] -> ()
      | line :: rest -> (
          match int_of_string_opt line with
            | Some i when i >= 0 && i < count && string_of_int i = line ->
                Bytes.set claimed i '\001';
                go rest
            | _ -> ())
    in
    go lines;
    claimed

  let rec without_last = function
    | [] | [_] -> []
    | line :: rest -> line :: without_last rest

  (* What follows the last newline is a claim cut short, whose digits could
     read as another chunk's index. *)
  let parse ~count id text =
    let expected = header id in
    let n = String.length expected in
    if String.length text < n || String.sub text 0 n <> expected then `Mismatch
    else
      `Claimed
        (claimed_of_lines ~count
           (without_last
              (String.split_on_char '\n'
                 (String.sub text n (String.length text - n)))))

  let is_claimed claimed i = Bytes.get claimed i = '\001'

  let claimed_count claimed =
    let n = ref 0 in
    Bytes.iter (fun c -> if c = '\001' then incr n) claimed;
    !n
end

type on_disk = { size : int64; mtime : float }

(* ponytail: a finished file is known by its size and mtime, within what a
   coarse filesystem rounds an mtime to; hash it if that is ever not enough. *)
let mtime_slack = 2.

let decide ~count ~(identity : Record.identity) ~mtime ~record ~dst =
  let sized =
    match dst with Some d -> d.size = identity.Record.size | None -> false
  in
  match record with
    | Some text -> (
        match Record.parse ~count identity text with
          | `Claimed claimed when sized -> `Resume claimed
          | `Claimed _ | `Mismatch -> `Fresh)
    | None -> (
        match dst with
          | Some d when sized && Float.abs (d.mtime -. mtime) <= mtime_slack ->
              `Already_there
          | _ -> `Fresh)

let segments rel = List.filter (fun s -> s <> "") (String.split_on_char '/' rel)

(* Names come off a store, and a destination is somebody's disk. *)
let stays_inside rel =
  List.for_all (fun s -> s <> "." && s <> "..") (segments rel)

(* A file lands by its name and a folder keeps its own, the root having none. *)
let landing ~dst ~asked ~rel =
  let base = Filename.dirname asked in
  let kept =
    if base = "." || base = "" then rel
    else
      String.sub rel
        (String.length base + 1)
        (String.length rel - String.length base - 1)
  in
  Filename.concat dst kept

module Over
    (Io : Io.S)
    (Files : Fs.S with type 'a io := 'a Io.t)
    (Syscalls : Syscalls.S with type 'a io := 'a Io.t and type fd = Files.fd)
    (Pools : Bounded.S with type 'a io := 'a Io.t)
    (Tree : Inode_tree.OVER with type 'a io := 'a Io.t and type pool := Pools.t)
    (Staged : Staged_manifest.OVER with type 'a io := 'a Io.t)
    (Remote : Remote.OVER with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Lk = Logical_key.Make (C)
    module Tree = Tree.Make (C)
    module Mfs = Staged.Make (C)
    module R = Remote.Make (C)

    type file = { rel : string; dst_path : string; manifest : Manifest.t }
    type opened = { fd : Files.fd; record_fd : Files.fd }

    type job = {
      file : file;
      record_path : string;
      claimed : Bytes.t;
      fresh : bool;
      mutable opening : opened Io.t option;
      mutable left : int;
      mutable in_flight : int;
      mutable closed : bool;
      mutable outcome : outcome option;
    }

    let no_such asked =
      Failure
        (Printf.sprintf "%s: no such file or folder in %s"
           (if asked = "" then "/" else asked)
           C.domain_name)

    let files_under ~dst ~asked folder_id =
      let key = if asked = "" then Lk.root else Lk.dir asked in
      Tree.fold_tree ~on_unusable:`Fail ~folder_id ~key
        (fun acc key entry ->
          match entry.Inode_tree.body with
            | Inode_tree.Dir _ -> Io.return acc
            | Inode_tree.File manifest ->
                let rel =
                  Logical_key.path
                    (Logical_key.file_in key (Manifest.recorded_name manifest))
                in
                Io.return
                  ({ rel; dst_path = landing ~dst ~asked ~rel; manifest } :: acc))
        []

    let files_at ~dst asked =
      let* found = Tree.find ~folder_id:Stored_key.root_id (segments asked) in
      match found with
        | `Missing -> Io.fail (no_such asked)
        | `Folder id -> files_under ~dst ~asked id
        | `File { Inode_tree.body = Inode_tree.File manifest; _ } ->
            Io.return
              [
                {
                  rel = asked;
                  dst_path = landing ~dst ~asked ~rel:asked;
                  manifest;
                };
              ]
        | `File _ -> Io.fail (no_such asked)

    let pending_under asked =
      let under () =
        let+ entries = Mfs.entries ~rel_dir:asked ~deep:true in
        List.map fst entries
      in
      let+ keys =
        if asked = "" then under ()
        else
          let* is_file = Mfs.exists (Lk.file asked) in
          if is_file then Io.return [Lk.file asked] else under ()
      in
      List.map Logical_key.path keys

    (* Two names asked for can land on one path, and the second would be
       written over the first with both reported as exported. *)
    let refuse_collisions files =
      let seen = Hashtbl.create (List.length files) in
      List.iter
        (fun f ->
          (match Hashtbl.find_opt seen f.dst_path with
            | Some other when other <> f.rel ->
                failwith
                  (Printf.sprintf "%s and %s would both be written to %s" other
                     f.rel f.dst_path)
            | _ -> ());
          Hashtbl.replace seen f.dst_path f.rel)
        files

    let identity file =
      let m = file.manifest in
      {
        Record.h1 = Manifest.h1 m;
        h2 = Manifest.h2 m;
        size = Manifest.size m;
        chunk_size = Manifest.chunk_size m;
        dst = file.dst_path;
      }

    let record_path file =
      Cache_layout.export_record_path ~cache_root:C.cache_root
        ~domain_name:C.domain_name file.dst_path

    let on_disk path =
      let* kind = Files.lstat_kind path in
      match kind with
        | `File size ->
            let+ st = Files.stat_opt_large path in
            Option.map
              (fun st -> { size; mtime = st.Unix.LargeFile.st_mtime })
              st
        | `Dir | `Symlink _ | `Missing -> Io.return None

    let job_of file =
      let count = Manifest.count file.manifest in
      let record_path = record_path file in
      let* record = Files.read_file_opt record_path in
      let+ dst = on_disk file.dst_path in
      let job ~fresh claimed =
        `Job
          {
            file;
            record_path;
            claimed;
            fresh;
            opening = None;
            left = count - Record.claimed_count claimed;
            in_flight = 0;
            closed = false;
            outcome = None;
          }
      in
      if Manifest.symlink file.manifest <> None then
        job ~fresh:true (Bytes.make count '\000')
      else (
        match
          decide ~count ~identity:(identity file)
            ~mtime:(Manifest.mtime file.manifest)
            ~record ~dst
        with
          | `Already_there -> `Already_there file
          | `Fresh -> job ~fresh:true (Bytes.make count '\000')
          | `Resume claimed -> job ~fresh:false claimed)

    let claimed_bytes job =
      let m = job.file.manifest in
      let total = ref 0L in
      Bytes.iteri
        (fun i c ->
          if c = '\001' then
            total :=
              Int64.add !total
                (Int64.of_int
                   (Chunks.length_of ~size:(Manifest.size m)
                      ~chunk_size:(Manifest.chunk_size m) i)))
        job.claimed;
      !total

    let no_space ~dir ~size =
      Failure
        (Printf.sprintf "not enough space in %s: needs %s%s" dir
           (Metrics.human_bytes (Int64.to_int size))
           (match Fs.disk_space dir with
             | Some d ->
                 ", "
                 ^ Metrics.human_bytes (Int64.to_int d.Fs.avail)
                 ^ " available"
             | None -> ""))

    let create_reserved job =
      let path = job.file.dst_path and size = Manifest.size job.file.manifest in
      (* Unlinked rather than truncated: what is there may be a symlink, and
         writing through one fills a file nobody asked to export to. *)
      let* () = Files.unlink_quiet path in
      let* fd =
        Syscalls.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL] 0o644
      in
      Io.catch
        (fun () ->
          let+ () = Files.reserve ~size fd in
          fd)
        (fun exn ->
          let* () = Syscalls.close fd in
          let* () = Files.unlink_quiet path in
          let* () = Files.unlink_quiet job.record_path in
          match exn with
            | Unix.Unix_error (Unix.ENOSPC, _, _) ->
                Io.fail (no_space ~dir:(Filename.dirname path) ~size)
            | exn -> Io.fail exn)

    (* The record lands before the file does, so a run cut short leaves either
       nothing or a record that claims less than the disk holds. *)
    let open_job ~on_event job =
      on_event
        (`Started
           {
             rel = job.file.rel;
             size = Manifest.size job.file.manifest;
             present = claimed_bytes job;
           });
      let* () = Files.ensure_parent job.file.dst_path in
      let* () = Files.ensure_parent job.record_path in
      let* fd =
        if job.fresh then
          let* () =
            Files.atomic_write job.record_path
              (Record.header (identity job.file))
          in
          create_reserved job
        else Syscalls.openfile job.file.dst_path [Unix.O_WRONLY] 0
      in
      let+ record_fd =
        Syscalls.openfile job.record_path [Unix.O_WRONLY; Unix.O_APPEND] 0
      in
      { fd; record_fd }

    let opened ~on_event job =
      match job.opening with
        | Some opening -> opening
        | None ->
            let opening = open_job ~on_event job in
            job.opening <- Some opening;
            opening

    let close_job job =
      match job.opening with
        | Some opening when not job.closed ->
            job.closed <- true;
            Io.catch
              (fun () ->
                let* o = opening in
                let* () = Syscalls.close o.fd in
                Syscalls.close o.record_fd)
              (fun _ -> Io.return ())
        | _ -> Io.return ()

    let settle ~on_event job outcome =
      if job.outcome = None then begin
        job.outcome <- Some outcome;
        on_event (`Finished (job.file.rel, outcome))
      end

    let finish ~on_event job =
      let mtime = Manifest.mtime job.file.manifest in
      let* () = close_job job in
      let* () = Syscalls.utimes job.file.dst_path mtime mtime in
      let+ () = Files.unlink_quiet job.record_path in
      settle ~on_event job `Exported

    let claim o i =
      let line = Bytes.of_string (Record.claim i) in
      let+ written = Syscalls.write o.record_fd line 0 (Bytes.length line) in
      if written <> Bytes.length line then failwith "export record: short write"

    (* ponytail: an fsync a chunk, which is what lets the record be believed;
       batch the claims behind one if the fsyncs ever show in a profile. *)
    let write_chunk ~on_event job i =
      let m = job.file.manifest in
      let chunk_size = Manifest.chunk_size m in
      let* o = opened ~on_event job in
      let* body = R.get_verified_chunk ~chunk_key:(Manifest.key m i) in
      let expected = Chunks.length_of ~size:(Manifest.size m) ~chunk_size i in
      if Bigstring.length body <> expected then
        failwith
          (Printf.sprintf "chunk %d of %s: %d bytes where the manifest says %d"
             i job.file.rel (Bigstring.length body) expected);
      let* () =
        Files.pwrite_all o.fd body ~offset:(Chunks.offset_of ~chunk_size i)
      in
      let* () = Syscalls.fsync o.fd in
      let+ () = claim o i in
      job.left <- job.left - 1;
      on_event (`Landed (job.file.rel, expected))

    let export_symlink ~on_event job target =
      let path = job.file.dst_path in
      let* () = Files.ensure_parent path in
      let* () = Files.unlink_quiet path in
      let+ () = Syscalls.symlink target path in
      settle ~on_event job `Exported_symlink

    (* Never raises: [each] stops every worker at the first failure, and one
       file that cannot be had is not a reason to abandon the others. *)
    let guarded ~on_event job work =
      if job.outcome <> None then Io.return ()
      else begin
        job.in_flight <- job.in_flight + 1;
        let* () =
          Io.catch work (fun exn ->
              settle ~on_event job
                (`Failed
                   (match exn with
                     | Failure m | Backend.Backend_error m -> m
                     | exn -> Printexc.to_string exn));
              Io.return ())
        in
        job.in_flight <- job.in_flight - 1;
        let* () =
          if job.left = 0 && job.outcome = None && job.in_flight = 0 then
            Io.catch
              (fun () -> finish ~on_event job)
              (fun exn ->
                settle ~on_event job (`Failed (Printexc.to_string exn));
                Io.return ())
          else Io.return ()
        in
        if job.outcome <> None && job.in_flight = 0 then close_job job
        else Io.return ()
      end

    (* Chunk by chunk through the jobs in order, so the files open at once are
       the few the workers are spread over rather than all of them. *)
    let cursor ~on_event jobs =
      let jobs = Array.of_list jobs in
      let j = ref 0 and i = ref 0 in
      let rec next () =
        if !j >= Array.length jobs then None
        else (
          let job = jobs.(!j) in
          let count = Bytes.length job.claimed in
          let advance () =
            incr j;
            i := 0
          in
          match Manifest.symlink job.file.manifest with
            | Some target ->
                advance ();
                Some
                  (fun () ->
                    guarded ~on_event job (fun () ->
                        export_symlink ~on_event job target))
            | None when job.left = 0 && !i = 0 ->
                advance ();
                Some
                  (fun () ->
                    guarded ~on_event job (fun () ->
                        if job.fresh then
                          let+ (_ : opened) = opened ~on_event job in
                          ()
                        else Io.return ()))
            | None ->
                while !i < count && Record.is_claimed job.claimed !i do
                  incr i
                done;
                if !i >= count || job.outcome <> None then begin
                  advance ();
                  next ()
                end
                else (
                  let index = !i in
                  incr i;
                  Some
                    (fun () ->
                      guarded ~on_event job (fun () ->
                          write_chunk ~on_event job index))))
      in
      next

    let tally jobs already_there pending =
      List.fold_left
        (fun s job ->
          match job.outcome with
            | Some (`Exported | `Exported_symlink) ->
                { s with exported = s.exported + 1 }
            | Some `Already_there ->
                { s with already_there = s.already_there + 1 }
            | Some (`Failed _) | None -> { s with failed = s.failed + 1 })
        {
          exported = 0;
          already_there = List.length already_there;
          failed = 0;
          pending;
        }
        jobs

    let run ?(on_event = fun (_ : event) -> ()) ~dst ~paths () =
      if Filename.is_relative dst then
        invalid_arg "Export.run: the destination must be absolute";
      let paths =
        if paths = [] then [""]
        else List.map (fun p -> String.concat "/" (segments p)) paths
      in
      let* files = map_s (files_at ~dst) paths in
      let files =
        List.sort_uniq
          (fun a b -> compare (a.rel, a.dst_path) (b.rel, b.dst_path))
          (List.concat files)
      in
      (match List.find_opt (fun f -> not (stays_inside f.rel)) files with
        | Some f -> failwith (f.rel ^ ": not a name to write under " ^ dst)
        | None -> ());
      refuse_collisions files;
      let* pending = map_s pending_under paths in
      let pending = List.sort_uniq compare (List.concat pending) in
      let* decided = map_s job_of files in
      let jobs =
        List.filter_map (function `Job j -> Some j | _ -> None) decided
      and already_there =
        List.filter_map
          (function `Already_there f -> Some f | _ -> None)
          decided
      in
      let sum f l = List.fold_left (fun acc x -> Int64.add acc (f x)) 0L l in
      let size f = Manifest.size f.manifest in
      on_event
        (`Plan
           {
             files = List.length files;
             bytes = sum size files;
             present =
               Int64.add (sum size already_there) (sum claimed_bytes jobs);
           });
      List.iter
        (fun f -> on_event (`Finished (f.rel, `Already_there)))
        already_there;
      let* () = Files.mkdir_p dst in
      (* The width is the domain's read budget: a worker holds one chunk body,
         so this is also the most of them in memory at once. *)
      let+ () = Pools.each ~width:C.max_downloads (cursor ~on_event jobs) in
      tally jobs already_there pending
  end
end
