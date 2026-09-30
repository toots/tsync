open Tsync_core

let fields =
  Field_spec.
    [
      f ~required:true ~check:absolute_or_home "path" "Store root" Path;
      f ~default:"true" "verifyWrites" "Verify chunk writes" Bool;
    ]

let temp_name () = ".tsync-tmp-" ^ Ids.short () ^ ".tmp"

let is_gc_lock rel =
  match String.split_on_char '/' rel with
    | ["tsync"; _; "gc-run.lock"] -> true
    | _ -> false

let path = Local_path.path
let check_no_links = Local_path.check_no_links

(* Store files are replaced by rename, never modified in place, so a mapping
   stays valid (P6); a network mount could fault one, so it is read instead. *)
let read_opt ~mappable root key =
  match Fs.open_nofollow (path root key) with
    | None -> None
    | Some fd ->
        Some
          (Fs.with_fd fd
             (if mappable () then Fs.map_fd else Fs.read_fd_bigstring))

let write_body fd body =
  Fs.pwrite_all fd body ~boff:0 ~len:(Bigstring.length body) ~off:0

let mkdirs root key =
  let dir = Filename.dirname (Filename.concat root (Key.to_string key)) in
  Fs.mkdir_p ~perm:0o755 dir

(* Temporary, fsync, rename, directory fsync; retried once when a concurrent
   removal of an empty parent got in the way. *)
let durable_write root key body =
  let rec attempt n =
    let p = path root key in
    mkdirs root key;
    let dir = Filename.dirname p in
    let tmp = Filename.concat dir (temp_name ()) in
    match
      let fd = Fs.openfile ~perm:0o644 tmp [O_WRONLY; O_CREAT; O_EXCL] in
      Fs.with_fd fd (fun fd ->
          write_body fd body;
          Fs.fsync fd);
      Fs.rename tmp p;
      Fs.fsync_dir dir
    with
      | () -> ()
      | exception (Fail.E { kind = Absent; _ } as e) ->
          Fs.unlink_quiet tmp;
          if n = 0 then attempt 1 else raise e
      | exception e ->
          Fs.unlink_quiet tmp;
          raise e
  in
  attempt 0

let rec claim ~mappable root key body retries =
  let p = path root key in
  mkdirs root key;
  let dir = Filename.dirname p in
  let tmp = Filename.concat dir (temp_name ()) in
  let fd = Fs.openfile ~perm:0o644 tmp [O_WRONLY; O_CREAT; O_EXCL] in
  Fs.with_fd fd (fun fd ->
      write_body fd body;
      Fs.fsync fd);
  let outcome =
    Fun.protect
      ~finally:(fun () -> Fs.unlink_quiet tmp)
      (fun () ->
        match Fs.eintr (fun () -> Unix.link tmp p) with
          | () -> `Won
          | exception Unix.Unix_error (Unix.EEXIST, _, _) -> `Taken
          | exception
              Unix.Unix_error
                ((Unix.EPERM | Unix.EOPNOTSUPP | Unix.EMLINK), _, _) -> (
              match Fs.rename_noreplace tmp p with
                | () -> `Won
                | exception Fail.E { kind = Exists; _ } -> `Taken
                | exception Fail.E { kind = Refused; _ } ->
                    Fail.raise_ Fail.Refused
                      "%s: this filesystem cannot claim a name" p)
          | exception Unix.Unix_error (e, fn, a) ->
              raise (Fail.E (Fail.of_unix e fn a)))
  in
  Fs.fsync_dir dir;
  match outcome with
    | `Won -> Store.Won
    | `Taken -> (
        match read_opt ~mappable root key with
          | Some holder when Bigstring.equal holder body -> Store.Won
          | Some holder -> Store.Held holder
          | None ->
              if retries <= 0 then
                Fail.raise_ Fail.Load "%s: the holder vanished during the claim"
                  (Key.to_string key)
              else claim ~mappable root key body (retries - 1))

let entry_of rel (st : Unix.LargeFile.stats) =
  {
    Store.key = rel;
    size = Int64.to_int st.st_size;
    last_modified = st.st_mtime;
    etag = None;
  }

let list name root prefix =
  let prefix = Key.prefix_to_string prefix in
  let base =
    if prefix = "" then root
    else Filename.concat root (String.sub prefix 0 (String.length prefix - 1))
  in
  if prefix <> "" then check_no_links root (prefix ^ "x");
  let acc = ref [] in
  let rec walk dir rel =
    match Fs.readdir_opt dir with
      | None -> ()
      | Some names ->
          List.iter
            (fun n ->
              if not (Names.is_temp_name n) then (
                let p = Filename.concat dir n
                and r = if rel = "" then n else rel ^ "/" ^ n in
                match Fs.lstat_opt p with
                  | Some ({ st_kind = S_REG; _ } as st) ->
                      if not (is_gc_lock (prefix ^ r)) then
                        Option.iter
                          (fun key -> acc := entry_of key st :: !acc)
                          (Store.listed name (prefix ^ r))
                  | Some { st_kind = S_DIR; _ } -> walk p r
                  | _ -> ()))
            names
  in
  (match Fs.lstat_opt base with
    | Some { st_kind = S_DIR; _ } -> walk base ""
    | _ -> ());
  !acc

let marker_body = Corruption_marker.body

(* 06 §9: read back what was just written, never the argument, and file or
   clear the chunk's marker. A mismatch never fails the put. *)
let verify_written ~read root key =
  match Key.marker_of key with
    | None -> ()
    | Some marker -> (
        let leaf = Key.leaf key in
        let marker_write body =
          durable_write root marker (Bigstring.of_string body)
        in
        match read key with
          | exception Fail.E f ->
              marker_write (marker_body ~reason:f.reason None)
          | None ->
              marker_write (marker_body ~reason:"vanished after write" None)
          | Some b ->
              let computed = Xxh.dual_bigstring b in
              if computed = leaf then (
                match Fs.release (path root marker) with _ -> ())
              else
                marker_write (marker_body ~computed (Some (Bigstring.length b)))
        )

let expand_home p =
  if String.starts_with ~prefix:"~/" p then
    Filename.concat (Sys.getenv "HOME") (String.sub p 2 (String.length p - 2))
  else p

let create ?(verify_writes = true) ~name root =
  let root = expand_home root in
  let health = Health.create name in
  let network = Atomic.make None in
  let mappable () =
    match Atomic.get network with
      | Some n -> not n
      | None ->
          let n = try Fs.is_network_fs root with _ -> true in
          Atomic.set network (Some n);
          not n
  in
  (* Only link-kind failures (a network filesystem away) count against it. *)
  let fed f =
    match f () with
      | v -> v
      | exception (Fail.E { kind = Link; reason; _ } as e) ->
          ignore (Health.lost ~reason health);
          raise e
  in
  let spaces = Chunk_spaces.create root in
  let read_opt key =
    Chunk_spaces.read spaces key (fun key -> read_opt ~mappable root key)
  in
  let put ?mode:_ key body =
    fed (fun () ->
        Chunk_spaces.gate spaces ~key
          ~body:(fun () -> body)
          (fun () -> durable_write root key body);
        if verify_writes then verify_written ~read:read_opt root key)
  in
  let get_range key off len =
    fed (fun () ->
        Chunk_spaces.read spaces key @@ fun key ->
        match Fs.open_nofollow (path root key) with
          | None -> None
          | Some fd ->
              Fs.with_fd fd (fun fd ->
                  if mappable () then (
                    let b = Fs.map_fd fd in
                    let size = Bigstring.length b in
                    if off >= size then Some Bigstring.empty
                    else Some (Bigstring.sub b ~off ~len:(min len (size - off))))
                  else (
                    let size =
                      Int64.to_int
                        (Fs.sys (fun () -> Unix.LargeFile.fstat fd)).st_size
                    in
                    if off >= size then Some Bigstring.empty
                    else (
                      let n = min len (size - off) in
                      let buf = Bigstring.create n in
                      let got = Fs.pread_full fd buf ~boff:0 ~len:n ~off in
                      Some (Bigstring.sub buf ~off:0 ~len:got)))))
  in
  let head_opt key =
    fed (fun () ->
        Chunk_spaces.read spaces key @@ fun key ->
        match Fs.lstat_opt (path root key) with
          | Some ({ st_kind = S_REG; _ } as st) -> Some (entry_of key st)
          | _ -> None)
  in
  let delete_one key =
    let p = path root key in
    match Fs.lstat_opt p with
      | Some { st_kind = S_REG; _ } ->
          let removed = Fs.release p in
          Fs.fsync_dir (Filename.dirname p);
          removed
      | _ -> false
  in
  let delete key =
    fed (fun () ->
        List.fold_left
          (fun removed k -> delete_one k || removed)
          false
          (Chunk_spaces.twins spaces key))
  in
  let delete_multi keys =
    fed (fun () ->
        let dirs = Hashtbl.create 16 in
        List.iter
          (fun key ->
            let p = path root key in
            match Fs.lstat_opt p with
              | Some { st_kind = S_REG; _ } ->
                  ignore (Fs.release p);
                  Hashtbl.replace dirs (Filename.dirname p) ()
              | _ -> ())
          (List.concat_map (Chunk_spaces.twins spaces) keys);
        Hashtbl.iter (fun d () -> Fs.fsync_dir d) dirs)
  in
  let copy src dst =
    fed (fun () ->
        let body () =
          match read_opt src with
            | Some b -> b
            | None ->
                Fail.absent ~op:"copy" "%s: no such object" (Key.to_string src)
        in
        Chunk_spaces.gate spaces ~key:dst ~body (fun () ->
            let s = path root src and d = path root dst in
            match Fs.lstat_opt s with
              | Some { st_kind = S_REG; _ } -> (
                  mkdirs root dst;
                  let tmp =
                    Filename.concat (Filename.dirname d) (temp_name ())
                  in
                  match Fs.eintr (fun () -> Unix.link s tmp) with
                    | () ->
                        (try Fs.rename tmp d
                         with e ->
                           Fs.unlink_quiet tmp;
                           raise e);
                        Fs.fsync_dir (Filename.dirname d)
                    | exception
                        Unix.Unix_error
                          ( ( Unix.EXDEV | Unix.EMLINK | Unix.EPERM
                            | Unix.EOPNOTSUPP ),
                            _,
                            _ ) ->
                        durable_write root dst (Fs.map_file s)
                    | exception Unix.Unix_error (e, fn, a) ->
                        raise (Fail.E (Fail.of_unix e fn a)))
              | _ ->
                  Fail.absent ~op:"copy" "%s: no such object"
                    (Key.to_string src)))
  in
  (* ponytail: polls at the interval; a directory watch would wake sooner. *)
  let watch key last =
    let current = try Store.token (read_opt key) with _ -> last in
    if current = last then Rt.sleep Store.watch_interval
  in
  Store.checked
    {
      Store.name;
      put;
      put_if_absent =
        (fun key body ->
          fed (fun () ->
              Chunk_spaces.gate spaces ~key
                ~body:(fun () -> body)
                (fun () -> claim ~mappable root key body 3)));
      get_opt = (fun key -> fed (fun () -> read_opt key));
      get_range;
      head_opt;
      delete;
      delete_multi;
      copy;
      list_prefix =
        (fun ?max_keys p ->
          fed (fun () ->
              let l =
                List.sort
                  (fun (a : Store.entry) b -> Key.compare a.key b.key)
                  (Chunk_spaces.list spaces p (list name root))
              in
              match max_keys with
                | Some n -> List.filteri (fun i _ -> i < n) l
                | None -> l));
      watch;
      get_many = None;
      list_many = None;
      verify_all = (fun _ -> `Unsupported);
      discard = (fun ~chunk_prefix:_ ~run:_ ~name:_ _ -> `Unsupported);
      capabilities = (fun _ -> { Store.no_caps with verified = verify_writes });
      fast_read = true;
      local_path = Some root;
      health;
      traffic = None;
    }

let () =
  Driver.register "local"
    {
      fields;
      linkless = true;
      create =
        (fun ~domain:_ ~admission:_ ~name fields ->
          let verify_writes =
            match List.assoc_opt "verifyWrites" fields with
              | Some (Field_spec.B b) -> b
              | _ -> true
          in
          match List.assoc_opt "path" fields with
            | Some (Field_spec.S root) -> create ~verify_writes ~name root
            | _ -> Fail.raise_ Fail.Invalid "backend %s: no path" name);
    }
