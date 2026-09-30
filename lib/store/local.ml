open Tsync_core

let fields =
  Field_spec.
    [
      f ~required:true ~check:absolute_or_home "path" "Store root" Path;
      f ~default:"true" "verifyWrites" "Verify chunk writes" Bool;
    ]

type gate =
  key:Key.t ->
  source:[ `Body of string | `Copy_of of Key.t ] ->
  (unit -> unit) ->
  unit

let temp_name () = ".tsync-tmp-" ^ Ids.short () ^ ".tmp"

let is_gc_lock rel =
  match String.split_on_char '/' rel with
    | ["tsync"; _; "gc-run.lock"] -> true
    | _ -> false

(* Every directory between the root and the key is refused if it is a
   symbolic link, so a link planted in the store cannot redirect an access. *)
let check_no_links root key =
  let parts = String.split_on_char '/' key in
  let rec go dir = function
    | [] | [_] -> ()
    | seg :: rest -> (
        let d = Filename.concat dir seg in
        match Fs.lstat_opt d with
          | Some { st_kind = S_LNK; _ } ->
              Fail.invalid "%s: a symbolic link inside the store" d
          | Some { st_kind = S_DIR; _ } -> go d rest
          | Some _ -> Fail.raise_ Fail.Refused "%s: not a directory" d
          | None -> ())
  in
  go root parts

let path root key =
  let key = Key.to_string key in
  check_no_links root key;
  Filename.concat root key

let read_opt root key =
  match Fs.open_nofollow (path root key) with
    | None -> None
    | Some fd -> Some (Fs.with_fd fd Fs.read_fd_all)

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
          Fs.write_all fd body;
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

let rec claim root key body retries =
  let p = path root key in
  mkdirs root key;
  let dir = Filename.dirname p in
  let tmp = Filename.concat dir (temp_name ()) in
  let fd = Fs.openfile ~perm:0o644 tmp [O_WRONLY; O_CREAT; O_EXCL] in
  Fs.with_fd fd (fun fd ->
      Fs.write_all fd body;
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
        match read_opt root key with
          | Some holder when holder = body -> Store.Won
          | Some holder -> Store.Held holder
          | None ->
              if retries <= 0 then
                Fail.raise_ Fail.Load "%s: the holder vanished during the claim"
                  (Key.to_string key)
              else claim root key body (retries - 1))

let is_reference_key key =
  match String.split_on_char '/' (Key.to_string key) with
    | "tsync" :: _ :: ("manifests" | "versions") :: _ -> true
    | _ -> false

let entry_of rel (st : Unix.LargeFile.stats) =
  {
    Store.key = rel;
    size = Int64.to_int st.st_size;
    last_modified = st.st_mtime;
    etag = None;
  }

let list name root prefix max_keys =
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
  let l = List.sort (fun (a : Store.entry) b -> Key.compare a.key b.key) !acc in
  match max_keys with Some n -> List.filteri (fun i _ -> i < n) l | None -> l

let marker_body ?computed ?reason size =
  Yojson.Safe.to_string
    (`Assoc
       (List.filter_map Fun.id
          [
            Option.map (fun c -> ("computed", `String c)) computed;
            Option.map (fun s -> ("size", `Int s)) size;
            Some ("at", `Float (Unix.gettimeofday ()));
            Option.map (fun r -> ("reason", `String r)) reason;
          ]))

(* 06 §9: read back what was just written, never the argument, and file or
   clear the chunk's marker. A mismatch never fails the put. *)
let verify_written root key =
  match Key.marker_of key with
    | None -> ()
    | Some marker -> (
        let leaf = Key.leaf key in
        match read_opt root key with
          | exception Fail.E f ->
              durable_write root marker (marker_body ~reason:f.reason None)
          | None ->
              durable_write root marker
                (marker_body ~reason:"vanished after write" None)
          | Some b ->
              let computed = Xxh.dual b in
              if computed = leaf then (
                match Fs.release (path root marker) with _ -> ())
              else
                durable_write root marker
                  (marker_body ~computed (Some (String.length b))))

let expand_home p =
  if String.starts_with ~prefix:"~/" p then
    Filename.concat (Sys.getenv "HOME") (String.sub p 2 (String.length p - 2))
  else p

let create ?(verify_writes = true)
    ?(gate : gate Atomic.t = Atomic.make (fun ~key:_ ~source:_ f -> f ())) ~name
    root =
  let root = expand_home root in
  let health = Health.create name in
  (* Only link-kind failures (a network filesystem away) count against it. *)
  let fed f =
    match f () with
      | v -> v
      | exception (Fail.E { kind = Link; reason; _ } as e) ->
          ignore (Health.lost ~reason health);
          raise e
  in
  let gated key source write =
    if is_reference_key key then (Atomic.get gate) ~key ~source write
    else write ()
  in
  let put ?mode:_ key body =
    fed (fun () ->
        gated key (`Body body) (fun () -> durable_write root key body);
        if verify_writes then verify_written root key)
  in
  let get_range key off len =
    fed (fun () ->
        match Fs.open_nofollow (path root key) with
          | None -> None
          | Some fd ->
              Fs.with_fd fd (fun fd ->
                  let size =
                    Int64.to_int
                      (Fs.sys (fun () -> Unix.LargeFile.fstat fd)).st_size
                  in
                  if off >= size then Some ""
                  else (
                    let n = min len (size - off) in
                    let buf = Fs.bigstring_create n in
                    let got = Fs.pread_full fd buf ~boff:0 ~len:n ~off in
                    Some (Fs.string_of_bigstring ~len:got buf))))
  in
  let head_opt key =
    fed (fun () ->
        match Fs.lstat_opt (path root key) with
          | Some ({ st_kind = S_REG; _ } as st) -> Some (entry_of key st)
          | _ -> None)
  in
  let delete key =
    fed (fun () ->
        let p = path root key in
        match Fs.lstat_opt p with
          | Some { st_kind = S_REG; _ } ->
              let removed = Fs.release p in
              Fs.fsync_dir (Filename.dirname p);
              removed
          | _ -> false)
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
          keys;
        Hashtbl.iter (fun d () -> Fs.fsync_dir d) dirs)
  in
  let copy src dst =
    fed (fun () ->
        gated dst (`Copy_of src) (fun () ->
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
                        durable_write root dst (Fs.read_file s)
                    | exception Unix.Unix_error (e, fn, a) ->
                        raise (Fail.E (Fail.of_unix e fn a)))
              | _ ->
                  Fail.absent ~op:"copy" "%s: no such object"
                    (Key.to_string src)))
  in
  (* ponytail: polls at the interval; a directory watch would wake sooner. *)
  let watch key last =
    let current = try Store.token (read_opt root key) with _ -> last in
    if current = last then Rt.sleep Store.watch_interval
  in
  Store.checked
    {
      Store.name;
      put;
      put_if_absent =
        (fun key body ->
          fed (fun () ->
              let r = ref Store.Won in
              gated key (`Body body) (fun () -> r := claim root key body 3);
              !r));
      get_opt = (fun key -> fed (fun () -> read_opt root key));
      get_range;
      head_opt;
      delete;
      delete_multi;
      copy;
      list_prefix =
        (fun ?max_keys p -> fed (fun () -> list name root p max_keys));
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
