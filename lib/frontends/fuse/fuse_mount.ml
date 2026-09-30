open Tsync_core
open Tsync_config
open Tsync_owner

let unmount_delay = 0.1
let failure_report_interval = 10.
let hidden_prefix = ".fuse_hidden"
let unbounded = Int64.shift_left 1L 50

type handle = {
  rel : string;
  read : Tsync_sync.Local_ops.handle option;
  mutable modified : bool;
  synchronous : bool;
}

(* 04 §3.3, fuse §4.10: a victim's content, bound to its hidden name until the
   last close; a write goes to a private scratch copy. *)
type retained = {
  content : Tsync_sync.Local_ops.handle;
  size : int;
  mtime : float;
  mutable scratch : string option;
}

type t = {
  engine : (module Tsync_sync.Engine.S);
  domain : Tsync_domain.Domain.t;
  allow_other : bool;
  uid : int;
  gid : int;
  handles : (int64, handle) Hashtbl.t;
  listings : (int64, string list) Hashtbl.t;
  hidden : (string, retained) Hashtbl.t;
  m : Mutex.t;
  next_fh : int Atomic.t;
  scratch_dir : string;
  opened : int Atomic.t;
  open_handles : int Atomic.t;
  bytes_read : int Atomic.t;
  bytes_written : int Atomic.t;
}

let errno e = raise (Unix.Unix_error (e, "", ""))

(* 07 §3.7: a worker hands its call to the scheduler and waits; an OS error is
   the answer, anything else reaches the binding's failure ring. *)
let call f =
  match Rt.run_sync f with
    | v -> v
    | exception Fail.E f -> errno (Fail.errno f.kind)

let locked t f = Mutex.protect t.m f

let rel path =
  if path = "/" then "" else String.sub path 1 (String.length path - 1)

let is_hidden rel =
  String.starts_with ~prefix:hidden_prefix (Filename.basename rel)

let fresh_fh t = Int64.of_int (Atomic.fetch_and_add t.next_fh 1)

(* security-model §8: another user under allowOther only reads. *)
let check_mutation t =
  if t.allow_other && (Fuse.get_context ()).uid <> t.uid then errno EACCES

let read_only t = t.domain.domain.read_only

let stats t ~kind ~perm ~nlink ~size ~mtime : Unix.LargeFile.stats =
  let perm = if read_only t then perm land 0o555 else perm in
  {
    st_dev = 0;
    st_ino = 0;
    st_kind = kind;
    st_perm = perm;
    st_nlink = nlink;
    st_uid = t.uid;
    st_gid = t.gid;
    st_rdev = 0;
    st_size = Int64.of_int size;
    st_atime = mtime;
    st_mtime = mtime;
    st_ctime = mtime;
  }

let retained_size r =
  match r.scratch with
    | Some s -> (Unix.LargeFile.stat s).st_size |> Int64.to_int
    | None -> r.size

let getattr t path _ =
  let rel = rel path in
  if is_hidden rel then (
    match locked t (fun () -> Hashtbl.find_opt t.hidden rel) with
      | Some r ->
          stats t ~kind:S_REG ~perm:0o644 ~nlink:0 ~size:(retained_size r)
            ~mtime:r.mtime
      | None -> errno ENOENT)
  else (
    let (module E : Tsync_sync.Engine.S) = t.engine in
    call (fun () ->
        if rel <> "" && E.kind rel = `Absent then errno ENOENT;
        let st = E.stat rel in
        match st.kind with
          | `Dir ->
              stats t ~kind:S_DIR ~perm:0o755 ~nlink:2 ~size:0 ~mtime:st.mtime
          | `File ->
              stats t ~kind:S_REG ~perm:0o644 ~nlink:1 ~size:st.size
                ~mtime:st.mtime
          | `Symlink ->
              stats t ~kind:S_LNK ~perm:0o777 ~nlink:1 ~size:st.size
                ~mtime:st.mtime))

let readlink t path =
  let (module E : Tsync_sync.Engine.S) = t.engine in
  call (fun () ->
      match (E.stat (rel path)).kind with
        | `Symlink -> E.readlink (rel path)
        | _ -> errno EINVAL)

let opendir t _ _ =
  { Fuse.default_file_info_update with fi_update_fh = Some (fresh_fh t) }

(* fuse §4.2: one snapshot per open directory handle, taken at its first
   readdir and served by offset. *)
let readdir t path offset (fi : Fuse.file_info) _ =
  let (module E : Tsync_sync.Engine.S) = t.engine in
  let names =
    match locked t (fun () -> Hashtbl.find_opt t.listings fi.fi_fh) with
      | Some names -> names
      | None ->
          let names =
            "." :: ".."
            :: call (fun () ->
                List.map
                  (fun (e : E.entry) -> e.name)
                  (E.list_children (rel path)))
          in
          locked t (fun () -> Hashtbl.replace t.listings fi.fi_fh names);
          names
  in
  List.filteri (fun i _ -> Int64.of_int i >= offset) names
  |> List.mapi (fun i name ->
      {
        Fuse.entry_name = name;
        entry_stats = None;
        entry_offset = Some (Int64.add offset (Int64.of_int (i + 1)));
        entry_flags = { fill_dir_plus = false };
      })

let releasedir t _ (fi : Fuse.file_info) =
  locked t (fun () -> Hashtbl.remove t.listings fi.fi_fh)

let mknod t path _ =
  check_mutation t;
  let (module E : Tsync_sync.Engine.S) = t.engine in
  call (fun () ->
      let rel = rel path in
      E.create rel ~exclusive:true;
      E.close rel)

let fopen t path (fi : Fuse.file_info) =
  let rel = rel path in
  let has f = List.mem f fi.fi_flags in
  let writing = has Unix.O_WRONLY || has O_RDWR || has O_TRUNC in
  if writing then check_mutation t;
  let read =
    if is_hidden rel then (
      if not (locked t (fun () -> Hashtbl.mem t.hidden rel)) then errno ENOENT;
      None)
    else (
      let (module E : Tsync_sync.Engine.S) = t.engine in
      call (fun () ->
          if E.kind rel <> `File then errno ENOENT;
          if has O_TRUNC then E.truncate rel 0;
          Some (E.open_read rel)))
  in
  let fh = fresh_fh t in
  locked t (fun () ->
      Hashtbl.replace t.handles fh
        {
          rel;
          read;
          modified = has O_TRUNC;
          synchronous = has O_SYNC || has O_DSYNC;
        });
  Atomic.incr t.opened;
  Atomic.incr t.open_handles;
  {
    Fuse.default_file_info_update with
    fi_update_fh = Some fh;
    fi_update_direct_io = true;
  }

let blit_into (buf : Fuse.buffer) s =
  let n = Bigstring.length s in
  Bigstring.blit ~src:s ~src_off:0 ~dst:buf ~dst_off:0 ~len:n;
  n

(* Straight into the kernel's buffer. *)
let scratch_read r (buf : Fuse.buffer) ~off =
  Fs.with_fd
    (Unix.openfile (Option.get r.scratch) [O_RDONLY; O_CLOEXEC] 0)
    (fun fd -> Fs.pread_full fd buf ~boff:0 ~len:(Bigstring.length buf) ~off)

let read t path (buf : Fuse.buffer) off (fi : Fuse.file_info) =
  let len = Bigarray.Array1.dim buf and off = Int64.to_int off in
  let rel = rel path in
  let n =
    match locked t (fun () -> Hashtbl.find_opt t.handles fi.fi_fh) with
      | Some { read = Some h; _ } ->
          let (module E : Tsync_sync.Engine.S) = t.engine in
          blit_into buf (call (fun () -> E.read h ~off ~len))
      | _ -> (
          match locked t (fun () -> Hashtbl.find_opt t.hidden rel) with
            | Some ({ scratch = Some _; _ } as r) -> scratch_read r buf ~off
            | Some r ->
                let (module E : Tsync_sync.Engine.S) = t.engine in
                blit_into buf (call (fun () -> E.read r.content ~off ~len))
            | None -> errno EBADF)
  in
  ignore (Atomic.fetch_and_add t.bytes_read n);
  n

(* fuse §4.10: the first write to a hidden name copies the retention aside. *)
let ensure_scratch t rel r =
  match r.scratch with
    | Some s -> s
    | None ->
        let (module E : Tsync_sync.Engine.S) = t.engine in
        Fs.mkdir_p ~perm:0o700 t.scratch_dir;
        let s = Filename.concat t.scratch_dir (Filename.basename rel) in
        Fs.with_fd
          (Unix.openfile s [O_WRONLY; O_CREAT; O_TRUNC; O_CLOEXEC] 0o600)
          (fun fd ->
            let step = 1 lsl 20 in
            let rec go off =
              if off < r.size then (
                let data =
                  call (fun () ->
                      E.read r.content ~off ~len:(min step (r.size - off)))
                in
                let n = Bigstring.length data in
                if n = 0 then errno EIO;
                Fs.pwrite_all fd data ~boff:0 ~len:n ~off;
                go (off + n))
            in
            go 0);
        r.scratch <- Some s;
        s

let write t path (buf : Fuse.buffer) off (fi : Fuse.file_info) =
  check_mutation t;
  let rel = rel path in
  let len = Bigarray.Array1.dim buf in
  if is_hidden rel then (
    match locked t (fun () -> Hashtbl.find_opt t.hidden rel) with
      | None -> errno EBADF
      | Some r ->
          let s = ensure_scratch t rel r in
          Fs.with_fd
            (Unix.openfile s [O_WRONLY; O_CLOEXEC] 0)
            (fun fd ->
              Fs.pwrite_all fd buf ~boff:0 ~len ~off:(Int64.to_int off)))
  else (
    let (module E : Tsync_sync.Engine.S) = t.engine in
    (* The kernel's buffer outlives the call, which waits for the engine. *)
    let data = Bigstring.sub buf ~off:0 ~len in
    let synchronous =
      match locked t (fun () -> Hashtbl.find_opt t.handles fi.fi_fh) with
        | Some h ->
            h.modified <- true;
            h.synchronous
        | None -> false
    in
    call (fun () ->
        E.write rel ~off:(Int64.to_int off) data;
        if synchronous then E.sync rel));
  ignore (Atomic.fetch_and_add t.bytes_written len);
  len

let truncate t path size fi =
  check_mutation t;
  let rel = rel path in
  if is_hidden rel then (
    match locked t (fun () -> Hashtbl.find_opt t.hidden rel) with
      | None -> errno ENOENT
      | Some r -> Unix.LargeFile.truncate (ensure_scratch t rel r) size)
  else (
    let (module E : Tsync_sync.Engine.S) = t.engine in
    let handle =
      Option.bind fi (fun (fi : Fuse.file_info) ->
          locked t (fun () -> Hashtbl.find_opt t.handles fi.fi_fh))
    in
    call (fun () ->
        E.truncate rel (Int64.to_int size);
        match handle with Some h -> h.modified <- true | None -> E.close rel))

let release t _ (fi : Fuse.file_info) =
  match
    locked t (fun () ->
        let h = Hashtbl.find_opt t.handles fi.fi_fh in
        Hashtbl.remove t.handles fi.fi_fh;
        h)
  with
    | None -> ()
    | Some h ->
        if Atomic.fetch_and_add t.open_handles (-1) <= 0 then
          Atomic.set t.open_handles 0;
        let (module E : Tsync_sync.Engine.S) = t.engine in
        call (fun () ->
            Option.iter E.close_read h.read;
            if h.modified then E.close h.rel)

let fsync t path _ _ =
  let rel = rel path in
  if not (is_hidden rel) then (
    let (module E : Tsync_sync.Engine.S) = t.engine in
    call (fun () -> E.sync rel))

let drop_hidden t rel =
  match
    locked t (fun () ->
        let r = Hashtbl.find_opt t.hidden rel in
        Hashtbl.remove t.hidden rel;
        r)
  with
    | None -> errno ENOENT
    | Some r ->
        Option.iter Fs.unlink_quiet r.scratch;
        let (module E : Tsync_sync.Engine.S) = t.engine in
        call (fun () -> E.release r.content)

let unlink t path =
  check_mutation t;
  let rel = rel path in
  if is_hidden rel then drop_hidden t rel
  else (
    let (module E : Tsync_sync.Engine.S) = t.engine in
    call (fun () -> E.delete rel))

let mkdir t path _ =
  check_mutation t;
  let (module E : Tsync_sync.Engine.S) = t.engine in
  call (fun () -> E.mkdir (rel path) ~exclusive:true)

let rmdir t path =
  check_mutation t;
  let (module E : Tsync_sync.Engine.S) = t.engine in
  call (fun () -> E.rmdir (rel path))

(* fuse §4.10: the library hides an open victim under a free hidden name; the
   content is retained there and the key deleted in the domain. *)
let hide t src dst =
  let (module E : Tsync_sync.Engine.S) = t.engine in
  call (fun () ->
      let st = E.stat src in
      let content = E.retain src in
      locked t (fun () ->
          Hashtbl.replace t.hidden dst
            { content; size = st.size; mtime = st.mtime; scratch = None });
      E.delete src)

let rename t src dst (flags : Fuse.rename_flags) =
  check_mutation t;
  if flags.rename_exchange || flags.rename_whiteout then errno EINVAL;
  let src = rel src and dst = rel dst in
  if is_hidden dst && not (is_hidden src) then hide t src dst
  else if is_hidden src || is_hidden dst then errno EINVAL
  else (
    let (module E : Tsync_sync.Engine.S) = t.engine in
    call (fun () ->
        E.atomically (fun () ->
            (match (E.kind src, E.kind dst) with
              | `File, `Dir -> errno EISDIR
              | `Dir, `File -> errno ENOTDIR
              | _ -> ());
            E.rename ~src ~dst ~exclusive:flags.rename_noreplace)))

let symlink t target path =
  check_mutation t;
  if t.domain.domain.symlinks <> `Keep then errno EPERM;
  let (module E : Tsync_sync.Engine.S) = t.engine in
  call (fun () -> E.symlink (rel path) ~target ~exclusive:true)

(* fuse §4.5: the tightest writable local member, else unbounded. *)
let statfs t _ : Fuse.Unix_util.statvfs =
  let avail, free, total =
    match Tsync_domain.Domain.capacity t.domain with
      | Some c -> c
      | None -> (unbounded, unbounded, unbounded)
  in
  let blocks n = Int64.div n 4096L in
  {
    f_bsize = 4096L;
    f_frsize = 4096L;
    f_blocks = blocks total;
    f_bfree = blocks free;
    f_bavail = blocks avail;
    f_files = Int64.max_int;
    f_ffree = Int64.max_int;
    f_favail = Int64.max_int;
    f_fsid = 0L;
    f_flag = 0L;
    f_namemax = 255L;
  }

let operations t =
  {
    Fuse.default_operations with
    getattr = getattr t;
    readlink = readlink t;
    mknod = mknod t;
    mkdir = mkdir t;
    unlink = unlink t;
    rmdir = rmdir t;
    symlink = symlink t;
    rename = rename t;
    link = (fun _ _ -> errno EPERM);
    chmod = (fun _ _ _ -> ());
    chown = (fun _ _ _ _ -> ());
    truncate = truncate t;
    utimens = (fun _ _ _ _ -> ());
    fopen = fopen t;
    read = read t;
    write = write t;
    statfs = statfs t;
    flush = (fun _ _ -> ());
    release = release t;
    fsync = fsync t;
    setxattr = (fun _ _ _ _ -> errno EOPNOTSUPP);
    getxattr = (fun _ _ -> errno EOPNOTSUPP);
    listxattr = (fun _ -> errno EOPNOTSUPP);
    removexattr = (fun _ _ -> errno EOPNOTSUPP);
    opendir = opendir t;
    readdir = readdir t;
    releasedir = releasedir t;
    fsyncdir = (fun _ _ _ -> ());
  }

(* fuse §4.7: invalidation blocks on the kernel, so it runs on a thread of its
   own, never inside a callback on the same path. *)
let invalidator () =
  let q = Queue.create () and m = Mutex.create () and c = Condition.create () in
  ignore
    (Thread.create
       (fun () ->
         while true do
           let path =
             Mutex.protect m (fun () ->
                 while Queue.is_empty q do
                   Condition.wait c m
                 done;
                 Queue.pop q)
           in
           try Fuse.invalidate_path path
           with e -> Log.debug "invalidate %s: %s" path (Printexc.to_string e)
         done)
       ());
  fun keys ->
    Mutex.protect m (fun () ->
        List.iter
          (fun k ->
            (* The root has no entry to drop: the kernel answers ENOSYS. *)
            if k <> "" then (
              Queue.push ("/" ^ k) q;
              match Filename.dirname k with
                | "." -> ()
                | d -> Queue.push ("/" ^ d) q))
          keys;
        Condition.signal c)

let report_failures () =
  let seen = ref (-1) in
  try
    while true do
      Stop.sleep failure_report_interval;
      let errors = Fuse.recent_errors () in
      Array.iter
        (fun (e : Fuse.recorded_error) ->
          if e.ticket > !seen then (
            if e.ticket > !seen + 1 && !seen >= 0 then
              Log.warn "fuse: %d handler failures went unreported"
                (e.ticket - !seen - 1);
            Log.warn "fuse: %s %s: %s" e.op e.path (Printexc.to_string e.exn);
            seen := e.ticket))
        errors
    done
  with Stop.Stopping -> ()

let run_command args =
  match
    Unix.create_process (List.hd args) (Array.of_list args) Unix.stdin
      Unix.stdout Unix.stderr
  with
    | pid ->
        let rec wait () =
          match Unix.waitpid [WNOHANG] pid with
            | 0, _ ->
                Rt.sleep 0.05;
                wait ()
            | _, WEXITED 0 -> true
            | _ -> false
        in
        wait ()
    | exception Unix.Unix_error _ -> false

(* fuse §6.2: a busy mount is detached lazily; the owner exits without waiting
   for the loop. *)
let unmount ~loop_ended mount_point done_ =
  Fun.protect ~finally:(fun () -> ignore (Rt.Promise.try_resolve done_ ()))
  @@ fun () ->
  Rt.sleep unmount_delay;
  if Atomic.get loop_ended then ()
  else if not (run_command ["fusermount3"; "-u"; mount_point]) then (
    Log.info "%s is busy; detaching it lazily" mount_point;
    if not (run_command ["fusermount3"; "-uz"; mount_point]) then
      Log.err "could not unmount %s; the next start clears it" mount_point)

(* The mount table writes a space, tab, newline or backslash as \ooo. *)
let unescape_mount s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i < n then
      if s.[i] = '\\' && i + 3 < n then (
        match int_of_string_opt ("0o" ^ String.sub s (i + 1) 3) with
          | Some c ->
              Buffer.add_char b (Char.chr (c land 255));
              go (i + 4)
          | None ->
              Buffer.add_char b s.[i];
              go (i + 1))
      else (
        Buffer.add_char b s.[i];
        go (i + 1))
  in
  go 0;
  Buffer.contents b

let mounted_at mount_point =
  match Fs.read_file_opt "/proc/self/mounts" with
    | None -> None
    | Some table ->
        String.split_on_char '\n' table
        |> List.find_map (fun line ->
            match String.split_on_char ' ' line with
              | source :: target :: fstype :: _
                when unescape_mount target = mount_point ->
                  Some (source, fstype)
              | _ -> None)

(* fuse §6.1: a stale tsync mount is detached; another filesystem there is
   refused. *)
let prepare mount_point =
  (match mounted_at mount_point with
    | Some ("tsync", _) ->
        ignore
          (Sys.command
             (Filename.quote_command "fusermount3" ["-uz"; mount_point]))
    | Some (source, fstype) ->
        Fail.raise_ Fail.Refused "%s already has %s (%s) mounted on it"
          mount_point source fstype
    | None -> ());
  Fs.mkdir_p mount_point

let options (d : Config.domain) =
  Option.value ~default:[]
    (Option.map
       (fun (f : Config.frontend) -> f.options)
       (Config.frontend d "fuse"))

let mount_point ~mount (d : Config.domain) =
  match mount with
    | Some m -> m
    | None -> (
        match Config.fstr (options d) "mountPoint" with
          | Some m -> m
          | None -> Paths.mount_point d.name)

(* 07 §3.7: FUSE owns the main thread, so the owner runs on another, and the
   main thread enters the loop only once the owner serves its socket. *)
let host ~mount domains ~run =
  let d = List.hd domains in
  let mount_point = mount_point ~mount d in
  let allow_other = Config.flag (options d) "allowOther" in
  let subtype =
    match Config.fstr (options d) "mountSubtype" with
      | Some s when String.trim s <> "" -> s
      | _ -> "sshfs"
  in
  let m = Mutex.create () and c = Condition.create () in
  let state = ref `Starting in
  let unmounted = Rt.Promise.create () in
  let loop_ended = Atomic.make false in
  let set s =
    Mutex.protect m (fun () ->
        state := s;
        Condition.broadcast c)
  in
  let present domain engine =
    let t =
      {
        engine;
        domain;
        allow_other;
        uid = Unix.getuid ();
        gid = Unix.getgid ();
        handles = Hashtbl.create 64;
        listings = Hashtbl.create 16;
        hidden = Hashtbl.create 4;
        m = Mutex.create ();
        next_fh = Atomic.make 1;
        scratch_dir =
          List.fold_left Filename.concat (Paths.cache_root ())
            [Domain_name.to_string d.name; "scratch"];
        opened = Atomic.make 0;
        open_handles = Atomic.make 0;
        bytes_read = Atomic.make 0;
        bytes_written = Atomic.make 0;
      }
    in
    let hooks =
      {
        Handler.no_hooks with
        changed = invalidator ();
        status_fields = (fun () -> [("mount", `String mount_point)]);
        stats_fields =
          (fun () ->
            [
              ("frontend", `String "fuse");
              ("mountPoint", `String mount_point);
              ("openHandles", `Int (Atomic.get t.open_handles));
              ("filesOpened", `Int (Atomic.get t.opened));
              ("bytesRead", `Int (Atomic.get t.bytes_read));
              ("bytesWritten", `Int (Atomic.get t.bytes_written));
              ("handlerFailures", `Int (Fuse.error_count ()));
            ]);
      }
    in
    let go () =
      prepare mount_point;
      Fs.rm_rf t.scratch_dir;
      Rt.spawn ~name:"fuse failures" report_failures;
      let (_unregister : unit -> unit) =
        Stop.on_request (fun () ->
            Rt.spawn ~name:"unmount" (fun () ->
                unmount ~loop_ended mount_point unmounted))
      in
      set (`Ready t)
    in
    (hooks, go)
  in
  (* fuse §6.2: once drained and unmounted the owner exits, without waiting for
     a loop a held descriptor keeps alive. *)
  let owner =
    Thread.create
      (fun () ->
        let code = run present in
        match Mutex.protect m (fun () -> !state) with
          | `Ready _ ->
              Rt.run_sync (fun () ->
                  try Rt.with_timeout 5. (fun () -> Rt.Promise.await unmounted)
                  with Rt.Timeout -> ());
              flush_all ();
              Unix._exit code
          | _ -> set (`Done code))
      ()
  in
  let rec wait () =
    match !state with
      | `Starting ->
          Condition.wait c m;
          wait ()
      | s -> s
  in
  match Mutex.protect m wait with
    | `Done code ->
        Thread.join owner;
        code
    | `Starting -> assert false
    | `Ready t ->
        let opts =
          String.concat ","
            ([
               "fsname=tsync";
               "subtype=" ^ subtype;
               "default_permissions";
               "entry_timeout=0";
               "attr_timeout=0";
               "negative_timeout=0";
             ]
            @ (if read_only t then ["ro"] else [])
            @ if allow_other then ["allow_other"] else [])
        in
        (try
           Fuse.main ~loop_mode:Multi_threaded
             [| "tsync"; mount_point; "-f"; "-o"; opts |]
             (operations t)
         with e -> Log.err "fuse: %s" (Printexc.to_string e));
        (* An external unmount ends the loop first; the owner stops and exits. *)
        Atomic.set loop_ended true;
        Stop.request ();
        Thread.join owner;
        0

let () = Owner.register_host "fuse" host
