type bigstring = Bigstring.t

external pread_ : Unix.file_descr -> bigstring -> int -> int -> int64 -> int
  = "tsync_pread"

external pwrite_ : Unix.file_descr -> bigstring -> int -> int -> int64 -> int
  = "tsync_pwrite"

external fsync_ : Unix.file_descr -> unit = "tsync_fsync"
external syncfs_ : Unix.file_descr -> unit = "tsync_syncfs"
external reserve_ : Unix.file_descr -> int64 -> unit = "tsync_reserve"
external statvfs_ : string -> int64 * int64 * int64 = "tsync_statvfs"
external flock_ : Unix.file_descr -> bool -> bool -> bool = "tsync_flock"
external funlock_ : Unix.file_descr -> unit = "tsync_funlock"
external rename_noreplace_ : string -> string -> unit = "tsync_rename_noreplace"
external clone_ : string -> string -> unit = "tsync_clone"
external terminal_columns_ : Unix.file_descr -> int = "tsync_terminal_columns"
external drop_mapped_pages : bigstring -> unit = "tsync_drop_mapped_pages"
external is_network_fs_ : string -> bool = "tsync_is_network_fs"
external pid_alive_ : int -> bool = "tsync_pid_alive"
external open_nofollow_ : string -> Unix.file_descr = "tsync_open_nofollow"
external is_macos_ : unit -> bool = "tsync_is_macos"
external peer_uid : Unix.file_descr -> int = "tsync_peer_uid"
external raise_nofile : int -> int = "tsync_raise_nofile"

let is_macos = is_macos_ ()
let rec eintr f = try f () with Unix.Unix_error (Unix.EINTR, _, _) -> eintr f

(* Every call is retried on EINTR and raises a classified failure. *)
let sys ?(op = "") f =
  try eintr f
  with Unix.Unix_error (e, fn, arg) ->
    raise (Fail.E (Fail.of_unix ~op e fn arg))

let absent_errno = function Unix.ENOENT | Unix.ENOTDIR -> true | _ -> false

let opt f =
  match eintr f with
    | v -> Some v
    | exception Unix.Unix_error (e, _, _) when absent_errno e -> None
    | exception Unix.Unix_error (e, fn, arg) ->
        raise (Fail.E (Fail.of_unix e fn arg))

let stat_opt p = opt (fun () -> Unix.LargeFile.stat p)
let lstat_opt p = opt (fun () -> Unix.LargeFile.lstat p)
let exists p = stat_opt p <> None

let kind p =
  match lstat_opt p with
    | None -> `Absent
    | Some st -> (
        match st.st_kind with
          | Unix.S_DIR -> `Dir
          | S_REG -> `File
          | S_LNK -> `Link
          | _ -> `Other)

let is_dir p =
  match stat_opt p with Some { st_kind = S_DIR; _ } -> true | _ -> false

let openfile ?(perm = 0o600) p flags =
  sys (fun () -> Unix.openfile p (Unix.O_CLOEXEC :: flags) perm)

let close fd = try Unix.close fd with _ -> ()
let with_fd fd f = Fun.protect ~finally:(fun () -> close fd) (fun () -> f fd)

let read_fd_all fd =
  let buf = Buffer.create 4096 and chunk = Bytes.create 65536 in
  let rec go () =
    let n = sys (fun () -> Unix.read fd chunk 0 65536) in
    if n > 0 then (
      Buffer.add_subbytes buf chunk 0 n;
      go ())
  in
  go ();
  Buffer.contents buf

let read_file_opt p =
  match opt (fun () -> Unix.openfile p [O_RDONLY; O_CLOEXEC] 0) with
    | None -> None
    | Some fd -> Some (with_fd fd read_fd_all)

let read_file p =
  match read_file_opt p with
    | Some s -> s
    | None -> Fail.absent "%s: no such file" p

let readdir_opt p =
  match opt (fun () -> Unix.opendir p) with
    | None -> None
    | Some dh ->
        Fun.protect
          ~finally:(fun () -> try Unix.closedir dh with _ -> ())
          (fun () ->
            let rec go acc =
              match eintr (fun () -> Unix.readdir dh) with
                | "." | ".." -> go acc
                | n -> go (n :: acc)
                | exception End_of_file -> acc
                | exception Unix.Unix_error (e, fn, a) ->
                    raise (Fail.E (Fail.of_unix e fn a))
            in
            Some (List.sort compare (go [])))

let readdir p = Option.value ~default:[] (readdir_opt p)

let write_all fd s =
  let b = Bytes.unsafe_of_string s in
  let rec go o =
    if o < Bytes.length b then (
      let n = sys (fun () -> Unix.write fd b o (Bytes.length b - o)) in
      if n <= 0 then Fail.raise_ Fail.Local "short write";
      go (o + n))
  in
  go 0

let fsync fd = sys (fun () -> fsync_ fd)

let fsync_dir d =
  match opt (fun () -> Unix.openfile d [O_RDONLY; O_CLOEXEC] 0) with
    | None -> ()
    | Some fd -> with_fd fd fsync

let mkdir_p ?(perm = 0o700) ?(durable = true) d =
  let rec go d =
    if d = "" || d = "/" || d = "." then ()
    else (
      match stat_opt d with
        | Some _ -> ()
        | None -> (
            go (Filename.dirname d);
            match eintr (fun () -> Unix.mkdir d perm) with
              | () -> if durable then fsync_dir (Filename.dirname d)
              | exception Unix.Unix_error (Unix.EEXIST, _, _) -> ()
              | exception Unix.Unix_error (e, fn, a) ->
                  raise (Fail.E (Fail.of_unix e fn a))))
  in
  go d

let unlink_quiet p = try eintr (fun () -> Unix.unlink p) with _ -> ()

(* Answers whether something was removed; any error but absence is raised. *)
let release p =
  match opt (fun () -> Unix.unlink p) with Some () -> true | None -> false

let temp_in dir = Filename.concat dir (Names.temp_name ())

let write_temp_with ?(perm = 0o600) dir write =
  let tmp = temp_in dir in
  let fd = openfile ~perm tmp [O_WRONLY; O_CREAT; O_EXCL] in
  (try
     with_fd fd (fun fd ->
         write fd;
         fsync fd)
   with e ->
     unlink_quiet tmp;
     raise e);
  tmp

let write_temp ?perm dir data =
  write_temp_with ?perm dir (fun fd -> write_all fd data)

let rename ?(op = "") a b = sys ~op (fun () -> Unix.rename a b)

let replace_gen ~dir_sync ?perm p data =
  let dir = Filename.dirname p in
  mkdir_p dir;
  let tmp = write_temp ?perm dir data in
  (try rename tmp p
   with e ->
     unlink_quiet tmp;
     raise e);
  if dir_sync then fsync_dir dir

let durable_replace ?perm p data = replace_gen ~dir_sync:true ?perm p data
let replace ?perm p data = replace_gen ~dir_sync:false ?perm p data

let replace_unsynced ?(perm = 0o600) p data =
  let dir = Filename.dirname p in
  mkdir_p dir;
  let tmp = temp_in dir in
  try
    with_fd
      (openfile ~perm tmp [O_WRONLY; O_CREAT; O_EXCL])
      (fun fd -> write_all fd data);
    rename tmp p
  with e ->
    unlink_quiet tmp;
    raise e

let link a b = sys (fun () -> Unix.link a b)

(* Durable create-if-absent: the winner's body is whole the instant its name
   appears. *)
let create_if_absent_with ?perm ~on_temp p data =
  let dir = Filename.dirname p in
  mkdir_p dir;
  let tmp = write_temp ?perm dir data in
  Fun.protect
    ~finally:(fun () -> unlink_quiet tmp)
    (fun () ->
      on_temp tmp;
      match eintr (fun () -> Unix.link tmp p) with
        | () ->
            fsync_dir dir;
            `Created
        | exception Unix.Unix_error (Unix.EEXIST, _, _) -> `Exists
        | exception
            Unix.Unix_error ((Unix.EPERM | Unix.EOPNOTSUPP | Unix.EMLINK), _, _)
          -> (
            match eintr (fun () -> rename_noreplace_ tmp p) with
              | () ->
                  fsync_dir dir;
                  `Created
              | exception Unix.Unix_error (Unix.EEXIST, _, _) -> `Exists
              | exception Unix.Unix_error (e, fn, a) ->
                  raise (Fail.E (Fail.of_unix e fn a)))
        | exception Unix.Unix_error (e, fn, a) ->
            raise (Fail.E (Fail.of_unix e fn a)))

let create_if_absent ?perm p data =
  create_if_absent_with ?perm ~on_temp:ignore p data

let append_durable ?(perm = 0o600) p line =
  let existed = exists p in
  if not existed then mkdir_p (Filename.dirname p);
  let fd = openfile ~perm p [O_WRONLY; O_CREAT; O_APPEND] in
  with_fd fd (fun fd ->
      write_all fd line;
      fsync fd);
  if not existed then fsync_dir (Filename.dirname p)

let rec rm_rf p =
  match lstat_opt p with
    | None -> ()
    | Some { st_kind = S_DIR; _ } ->
        List.iter (fun n -> rm_rf (Filename.concat p n)) (readdir p);
        ignore (opt (fun () -> Unix.rmdir p))
    | Some _ -> ignore (release p)

let pread fd buf ~boff ~len ~off =
  sys (fun () -> pread_ fd buf boff len (Int64.of_int off))

(* Short only at end of file. *)
let pread_full fd buf ~boff ~len ~off =
  let rec go got =
    if got >= len then got
    else (
      let n =
        pread fd buf ~boff:(boff + got) ~len:(len - got) ~off:(off + got)
      in
      if n = 0 then got else go (got + n))
  in
  go 0

let pwrite_all fd buf ~boff ~len ~off =
  let rec go done_ =
    if done_ < len then (
      let n =
        sys (fun () ->
            pwrite_ fd buf (boff + done_) (len - done_)
              (Int64.of_int (off + done_)))
      in
      if n <= 0 then Fail.raise_ Fail.Local "short write";
      go (done_ + n))
  in
  go 0

let write_temp_bigstring ?perm dir b =
  write_temp_with ?perm dir (fun fd ->
      pwrite_all fd b ~boff:0 ~len:(Bigstring.length b) ~off:0)

let reserve fd size =
  if size > 0 then (
    match eintr (fun () -> reserve_ fd (Int64.of_int size)) with
      | () -> ()
      | exception
          Unix.Unix_error ((Unix.EOPNOTSUPP | Unix.ENOSYS | Unix.EINVAL), _, _)
        ->
          sys (fun () -> Unix.LargeFile.ftruncate fd (Int64.of_int size))
      | exception Unix.Unix_error (e, fn, a) ->
          raise (Fail.E (Fail.of_unix e fn a)))

type space = { available : int64; free : int64; total : int64 }

let disk_space p =
  match statvfs_ p with
    | available, free, total -> Some { available; free; total }
    | exception _ -> None

let flock ?(exclusive = true) ?(block = false) fd =
  sys (fun () -> flock_ fd exclusive block)

(* The lock is taken on the temporary file, which becomes the name: no reader
   ever sees the file unlocked. *)
let create_if_absent_locked ?perm p data =
  let fd = ref None in
  let lock tmp =
    let f = openfile tmp [O_RDONLY] in
    fd := Some f;
    if not (flock ~block:true f) then
      Fail.raise_ Fail.Local "cannot lock %s" tmp
  in
  match create_if_absent_with ?perm ~on_temp:lock p data with
    | `Created -> `Created (Option.get !fd)
    | `Exists ->
        Option.iter Unix.close !fd;
        `Exists
    | exception e ->
        Option.iter Unix.close !fd;
        raise e

let funlock fd = funlock_ fd
let ignore_sigpipe () = Sys.set_signal Sys.sigpipe Sys.Signal_ignore
let rename_noreplace a b = sys (fun () -> rename_noreplace_ a b)
let clone a b = sys (fun () -> clone_ a b)

(* A missing path will be made on its nearest existing ancestor's filesystem. *)
let rec is_network_fs p =
  match is_network_fs_ p with
    | n -> n
    | exception Unix.Unix_error (ENOENT, _, _) when Filename.dirname p <> p ->
        is_network_fs (Filename.dirname p)
    | exception _ -> true

let pid_alive pid = pid_alive_ pid

(* ELOOP means the last component is a symbolic link. *)
let open_nofollow p = opt (fun () -> open_nofollow_ p)

(* A private read-only mapping: a file shorter than the mapping is an error,
   never extended. *)
let fd_size fd =
  (sys (fun () -> Unix.LargeFile.fstat fd)).st_size |> Int64.to_int

let map_fd fd =
  let size = fd_size fd in
  if size = 0 then Bigstring.empty
  else
    Bigarray.array1_of_genarray
      (sys (fun () ->
           Unix.map_file fd Bigarray.char Bigarray.c_layout false [| size |]))

let map_file p = with_fd (openfile p [O_RDONLY]) map_fd

let read_fd_bigstring fd =
  let size = fd_size fd in
  let b = Bigstring.create size in
  let n = pread_full fd b ~boff:0 ~len:size ~off:0 in
  if n = size then b else Bigstring.sub b ~off:0 ~len:n

let sweep_temps ?(older_than = 0.) dir =
  List.iter
    (fun n ->
      if Names.is_temp_name n then (
        let p = Filename.concat dir n in
        let dead =
          match Names.temp_owner n with
            | Some pid -> not (pid_alive pid)
            | None -> (
                match lstat_opt p with
                  | Some st -> Unix.gettimeofday () -. st.st_mtime > older_than
                  | None -> false)
        in
        if dead then rm_rf p))
    (try readdir dir with _ -> [])

let write_file_for_test p data =
  mkdir_p (Filename.dirname p);
  let fd = openfile ~perm:0o644 p [O_WRONLY; O_CREAT; O_TRUNC] in
  with_fd fd (fun fd -> write_all fd data)

let terminal_columns fd =
  match terminal_columns_ fd with 0 -> None | n -> Some n

let resolve_parent p =
  match
    List.rev
      (List.filter (fun s -> s <> "" && s <> ".") (String.split_on_char '/' p))
  with
    | [] -> "/"
    | leaf :: parents ->
        let parent = "/" ^ String.concat "/" (List.rev parents) in
        Filename.concat
          (try Unix.realpath parent with Unix.Unix_error _ -> parent)
          leaf

let syncfs dir =
  Option.iter
    (fun fd -> with_fd fd (fun fd -> sys (fun () -> syncfs_ fd)))
    (opt (fun () -> Unix.openfile dir [O_RDONLY; O_CLOEXEC] 0))
