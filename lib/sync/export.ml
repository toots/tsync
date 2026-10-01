open Tsync_core
open Tsync_checkout
open Tsync_remote

type outcome = Exported of int | Already_there | Failed of string

type report = {
  exported : int;
  bytes : int;
  already_there : int;
  failed : (string * string) list;
  pending : string list;
  cancelled : bool;
}

let mtime_slack = 2.

type file = { dest : string; manifest : Manifest.t }

let records_dir ~cache_root domain =
  List.fold_left Filename.concat cache_root
    [Domain_name.to_string domain; "exports"]

module Make (C : Context.S) = struct
  module T = Tree.Make (C)
  module R = Remote.Make (C)

  let segs p = if p = "" then [] else String.split_on_char '/' p

  (* §4.4 step 2: a file lands by its name, a folder keeps its name, the
     root's contents land as they are. *)
  let resolve ~dst path =
    match T.find Folder_id.root (segs path) with
      | `Missing ->
          Fail.raise_ Fail.Absent "%s: no such file or folder in %s" path
            (Domain_name.to_string C.domain)
      | `File m ->
          [{ dest = Filename.concat dst (Names.leaf_of path); manifest = m }]
      | `Folder id ->
          let base =
            if path = "" then dst else Filename.concat dst (Names.leaf_of path)
          in
          List.rev
            (T.fold_tree ~on_unusable:Fail_on_unusable id ~root_path:""
               (fun acc dir (e : Tree.entry) ->
                 match e.body with
                   | Dir _ -> acc
                   | File m ->
                       let rel = Names.join dir m.name in
                       { dest = Filename.concat base rel; manifest = m } :: acc)
               [])

  let check_names ~dst files =
    let seen = Hashtbl.create 64 in
    List.iter
      (fun f ->
        let rel =
          String.sub f.dest (String.length dst)
            (String.length f.dest - String.length dst)
        in
        if
          List.exists
            (fun s -> s = "." || s = "..")
            (String.split_on_char '/' rel)
        then
          Fail.raise_ Fail.Invalid "%s: a name the store holds is . or .."
            f.dest;
        if Hashtbl.mem seen f.dest then
          Fail.raise_ Fail.Invalid "two paths land on %s" f.dest;
        Hashtbl.replace seen f.dest ())
      files

  let header (m : Manifest.t) dest =
    Printf.sprintf "tsync-export 1 %s %s %d %d %s\n" m.h1 m.h2 m.size
      m.chunk_size (Names.escape_path dest)

  (* Reading stops at the first line that is not an in-range index spelled
     canonically; a torn last line has no newline and is ignored. *)
  let claimed body (m : Manifest.t) =
    let lines = String.split_on_char '\n' body in
    let lines =
      match List.rev lines with _torn :: rest -> List.rev rest | [] -> []
    in
    let rec go acc = function
      | l :: rest -> (
          match int_of_string_opt l with
            | Some i when i >= 0 && i < m.count && string_of_int i = l ->
                go (i :: acc) rest
            | _ -> acc)
      | [] -> acc
    in
    match lines with _header :: rest -> go [] rest | [] -> []

  let regular_of_size path size =
    match Unix.lstat path with
      | { st_kind = S_REG; st_size; st_mtime; _ } when st_size = size ->
          Some st_mtime
      | _ | (exception Unix.Unix_error _) -> None

  let export_one ~narrate ~cancelled ~cache_root f =
    let m = f.manifest in
    let dir = records_dir ~cache_root C.domain in
    Fs.mkdir_p dir;
    let record = Filename.concat dir (Xxh.dual f.dest) in
    let header = header m f.dest in
    Fs.mkdir_p (Filename.dirname f.dest);
    Fs.with_fd
      (Fs.openfile record [O_RDWR; O_CREAT])
      (fun lock ->
        if not (Fs.flock ~block:false lock) then
          Failed "busy: another export writes this destination"
        else (
          let existing = Fs.read_file_opt record in
          match m.link with
            | Some target ->
                (try Unix.unlink f.dest
                 with Unix.Unix_error (ENOENT, _, _) -> ());
                Unix.symlink target f.dest;
                Fs.unlink_quiet record;
                Exported 0
            | None ->
                let resume =
                  match existing with
                    | Some body
                      when String.starts_with ~prefix:header body
                           && regular_of_size f.dest m.size <> None ->
                        Some (claimed body m)
                    | _ -> None
                in
                let fresh_ok =
                  match (resume, existing) with
                    | None, (None | Some "") -> (
                        match regular_of_size f.dest m.size with
                          | Some mtime
                            when Float.abs (mtime -. m.mtime) <= mtime_slack ->
                              false
                          | _ -> true)
                    | _ -> true
                in
                if (not fresh_ok) && resume = None then (
                  Fs.unlink_quiet record;
                  Already_there)
                else (
                  let done_ =
                    match resume with
                      | Some l -> l
                      | None ->
                          (* The record before any byte of its file. *)
                          Unix.ftruncate lock 0;
                          ignore (Unix.lseek lock 0 SEEK_SET);
                          Fs.write_all lock header;
                          Fs.fsync lock;
                          Fs.fsync_dir dir;
                          (try Unix.unlink f.dest
                           with Unix.Unix_error (ENOENT, _, _) -> ());
                          let fd =
                            Fs.openfile ~perm:0o644 f.dest
                              [O_WRONLY; O_CREAT; O_EXCL]
                          in
                          (match Fs.reserve fd m.size with
                            | () -> Unix.close fd
                            | exception _ ->
                                Unix.close fd;
                                Fs.unlink_quiet f.dest;
                                Fs.unlink_quiet record;
                                let available =
                                  match
                                    Fs.disk_space (Filename.dirname f.dest)
                                  with
                                    | Some s ->
                                        Narrate.size (Int64.to_int s.available)
                                    | None -> "unknown"
                                in
                                Fail.raise_ Fail.Local
                                  "not enough space in %s: needs %s, %s \
                                   available"
                                  (Filename.dirname f.dest)
                                  (Narrate.size m.size) available);
                          []
                  in
                  let written = ref 0 in
                  Fs.with_fd (Fs.openfile f.dest [O_WRONLY]) (fun fd ->
                      for i = 0 to m.count - 1 do
                        if not (List.mem i done_) then (
                          Cancel.check cancelled;
                          let b = R.get_verified_chunk (Manifest.key m i) in
                          let len =
                            if m.size = 0 then 0
                            else Chunking.length ~size:m.size ~cs:m.chunk_size i
                          in
                          if Bigstring.length b <> len then
                            Fail.raise_ Fail.Corrupt
                              "chunk %d of %s has %d bytes, not %d" i f.dest
                              (Bigstring.length b) len;
                          Fs.pwrite_all fd b ~boff:0 ~len ~off:(i * m.chunk_size);
                          Fs.fsync fd;
                          Fs.append_durable record (string_of_int i ^ "\n");
                          written := !written + len;
                          Narrate.progress narrate "%s: chunk %d of %d" f.dest
                            (i + 1) m.count)
                      done);
                  Unix.utimes f.dest m.mtime m.mtime;
                  Fs.unlink_quiet record;
                  Exported !written)))

  let export ?(narrate = Narrate.none) ?(cancelled = Fun.const false)
      ~cache_root ~dst paths =
    if Filename.is_relative dst then
      Fail.raise_ Fail.Invalid "%s: the destination must be absolute" dst;
    let files = List.concat_map (resolve ~dst) paths in
    check_names ~dst files;
    let staged = Staged.create ~cache_root C.domain in
    let pending =
      List.concat_map
        (fun p -> List.map fst (Staged.edits_under staged p))
        paths
      |> List.sort_uniq compare
    in
    let total = List.fold_left (fun n f -> n + f.manifest.size) 0 files in
    Narrate.say narrate "planned %s (%s) into %s"
      (Narrate.count (List.length files) "file")
      (Narrate.size total) dst;
    let exported = ref 0 and already = ref 0 and bytes = ref 0 in
    let failed = ref [] and m = Mutex.create () and seen = ref 0 in
    let todo = ref files and settled = Hashtbl.create 64 in
    let next () =
      Mutex.protect m (fun () ->
          match !todo with
            | f :: rest when not (cancelled ()) ->
                todo := rest;
                Some f
            | _ -> None)
    in
    Rt.each ~width:C.max_downloads next (fun f ->
        let outcome =
          try export_one ~narrate ~cancelled ~cache_root f with
            | (Stop.Stopping | Rt.Cancelled) as e -> raise e
            | e -> Failed (Fail.classify e).reason
        in
        Mutex.protect m (fun () ->
            seen := !seen + f.manifest.size;
            Hashtbl.replace settled f.dest ();
            Narrate.progress narrate
              ~fraction:(float !seen /. float (max 1 total))
              "exported %s of %s" (Narrate.size !seen) (Narrate.size total);
            match outcome with
              | Exported n ->
                  incr exported;
                  bytes := !bytes + n
              | Already_there -> incr already
              | Failed reason ->
                  Narrate.say narrate "  %s failed: %s" f.dest reason;
                  failed := (f.dest, reason) :: !failed));
    let unsettled =
      List.filter_map
        (fun f ->
          if Hashtbl.mem settled f.dest then None
          else Some (f.dest, "not reached"))
        files
    in
    {
      exported = !exported;
      bytes = !bytes;
      already_there = !already;
      failed = List.sort compare (List.rev !failed @ unsettled);
      pending;
      cancelled = cancelled ();
    }
end

let record_grace = 30. *. 86400.

let sweep_records ~cache_root domain =
  let dir = records_dir ~cache_root domain in
  let now = Unix.gettimeofday () in
  List.fold_left
    (fun n name ->
      let path = Filename.concat dir name in
      match Unix.lstat path with
        | { st_kind = S_REG; st_mtime; _ } when now -. st_mtime > record_grace
          ->
            Fs.with_fd (Fs.openfile path [O_RDWR]) (fun fd ->
                if Fs.flock ~block:false fd then (
                  Fs.unlink_quiet path;
                  n + 1)
                else n)
        | _ | (exception Unix.Unix_error _) -> n)
    0
    (try Array.to_list (Sys.readdir dir) with Sys_error _ -> [])
