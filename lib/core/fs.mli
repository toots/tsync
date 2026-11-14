(** Local filesystem helpers (spec 01 §6.3–6.4) and the durable write primitives
    (durable-queue §3.2).

    Every call retries EINTR. A helper answers "absent" only for ENOENT or
    ENOTDIR, and raises every other error as a classified {!Fail.E}. *)

type bigstring = Bigstring.t

(** Retry on EINTR. *)
val eintr : (unit -> 'a) -> 'a

(** Retry on EINTR and turn Unix errors into classified failures. *)
val sys : ?op:string -> (unit -> 'a) -> 'a

(** [None] only for ENOENT/ENOTDIR. *)
val opt : (unit -> 'a) -> 'a option

val stat_opt : string -> Unix.LargeFile.stats option
val lstat_opt : string -> Unix.LargeFile.stats option

(** A file's times in nanoseconds since the epoch (02 §2.6). [created] is the
    [mtime] where the platform keeps no creation time, or keeps one before
    1980-01-02, the unset value of FAT and the zero of others. *)
type times = { mtime : int; created : int }

(** The wall clock, as [times] counts. *)
val now : unit -> int

(** Seconds, for the interfaces that take a float. *)
val seconds : int -> float

(** [created], or [mtime] where [created] is before 1980-01-02: FAT's unset
    1980-01-01 in any zone, or a platform's zero. Every creation time from
    outside goes through it, so one read from disk and one a frontend passes
    agree. *)
val creation : mtime:int -> int -> int

(** [t] carried over a file that holds [held]: a creation time never moves later
    (02 §2.6). *)
val carried_over : held:times -> times -> times

(** Of the link itself, not its target. *)
val times : string -> times

val ftimes : Unix.file_descr -> times

(** Whether {!set_times} sets [created]: Windows and macOS. Linux keeps a
    creation time but offers no call to set one. *)
val sets_created : bool

(** Of the link itself, like {!times}; [created] only where {!sets_created}. *)
val set_times : string -> times -> unit

val exists : string -> bool
val is_dir : string -> bool

(** The kind of what is at a path, without following a link. *)
val kind : string -> [ `Absent | `Dir | `File | `Link | `Other ]

(** [Unix.openfile], sharing deletion on Windows so that an open file never
    stops its replacement or removal (cloud-files §5.1). Raises [Unix_error]
    like it, for callers that sort errors themselves. *)
val unix_openfile :
  string -> Unix.open_flag list -> Unix.file_perm -> Unix.file_descr

val openfile : ?perm:int -> string -> Unix.open_flag list -> Unix.file_descr
val close : Unix.file_descr -> unit
val with_fd : Unix.file_descr -> (Unix.file_descr -> 'a) -> 'a

(** [f fd], closing [fd] if it raises: for a descriptor handed on when [f]
    returns, to its caller or to a fiber [f] spawns, and owed back otherwise
    (spec ocaml README, lesson 8). *)
val or_close : Unix.file_descr -> (Unix.file_descr -> 'a) -> 'a

val read_fd_all : Unix.file_descr -> string
val read_file_opt : string -> string option

(** Raises ABSENT for a missing file. *)
val read_file : string -> string

(** Sorted entries, without [.] and [..]; [None] for a missing directory. *)
val readdir_opt : string -> string list option

(** As {!readdir_opt}, a missing directory listing as empty. *)
val readdir : string -> string list

val write_all : Unix.file_descr -> string -> unit
val fsync : Unix.file_descr -> unit
val fsync_dir : string -> unit

(** Create a directory chain, fsyncing the parent of every directory created
    unless [durable] is false. *)
val mkdir_p : ?perm:int -> ?durable:bool -> string -> unit

(** Durable replace: temporary, fsync, rename, directory fsync. *)
val durable_replace : ?perm:int -> string -> string -> unit

(** Replace without the directory fsync: never torn, not yet durable. *)
val replace : ?perm:int -> string -> string -> unit

(** Durable create-if-absent by hard link (or no-replace rename). *)
val create_if_absent : ?perm:int -> string -> string -> [ `Created | `Exists ]

(** [create_if_absent], answering the created file's descriptor holding a BSD
    lock taken before the file had its name. *)
val create_if_absent_locked :
  ?perm:int -> string -> string -> [ `Created of Unix.file_descr | `Exists ]

(** One write of a whole line, then fsync. *)
val append_durable : ?perm:int -> string -> string -> unit

(** Unlink; answers whether something was there. *)
val release : string -> bool

(** Best-effort cleanup whose outcome nobody reads. *)
val unlink_quiet : string -> unit

(** Creates [p] holding [data] (mode [perm], 0600 by default, which on Windows
    is the access list of {!make_private}), whole or not at all; EXISTS when [p]
    exists, which is never replaced. *)
val create_new : ?perm:int -> string -> string -> unit

(** Remove a tree without following symbolic links. *)
val rm_rf : string -> unit

(** [Unix.rename] with POSIX semantics on Windows too: the destination is
    replaced even while it is open. Raises [Unix_error] like it. *)
val unix_rename : string -> string -> unit

(** [Unix.unlink] with POSIX semantics on Windows too: the name goes at once,
    though the file is open. Raises [Unix_error] like it. *)
val unix_unlink : string -> unit

val rename : ?op:string -> string -> string -> unit

(** Whether only this process's user can reach the file or directory: owned by
    it with no group or other mode bits, or on Windows owned by its SID with no
    entry, inherited or not, allowing anyone else (security-model §7.1). Raises
    [Unix_error]. *)
val is_private : string -> bool

(** Whether the file or directory belongs to this process's user: its uid, or on
    Windows its owner SID (security-model §7.3). Raises [Unix_error]. *)
val owned_by_this_user : string -> bool

(** On Windows, ties a child, as {!Unix.create_process} returned it, to this
    process's life: it is ended when this process ends, however it ends
    (cloud-files §5.2). Elsewhere nothing. Raises [Unix_error]. *)
val end_with_this_process : int -> unit

(** Whether Windows gave this process no handle for the stream, as it does a
    windowed program. Elsewhere false. *)
val std_handle_missing : [ `Stdin | `Stdout | `Stderr ] -> bool

(** A windowed program starts without standard handles: the null device stands
    in for each missing one, so printing works and a child spawned with them
    starts. Called first by every windowed entry point. *)
val attach_missing_handles : unit -> unit

(** Makes a file or directory private to this process's user: mode 0600 or 0700,
    or on Windows a protected access list whose one entry grants the user, which
    a directory passes on to what is created in it. Raises [Unix_error]. *)
val make_private : string -> unit

(** EEXIST when the target exists. *)
val rename_noreplace : string -> string -> unit

val link : string -> string -> unit

(** A fresh temporary name in [dir]. *)
val temp_in : string -> string

(** Runs [write] on a new temporary in [dir], then fsyncs it; the temporary is
    removed when [write] raises. *)
val write_temp_with : ?perm:int -> string -> (Unix.file_descr -> unit) -> string

(** Write [data] to a new temporary in [dir] and fsync it. *)
val write_temp : ?perm:int -> string -> string -> string

val write_temp_bigstring : ?perm:int -> string -> bigstring -> string

val pread :
  Unix.file_descr -> bigstring -> boff:int -> len:int -> off:int -> int

(** Reads until [len] or end of file. *)
val pread_full :
  Unix.file_descr -> bigstring -> boff:int -> len:int -> off:int -> int

val pwrite_all :
  Unix.file_descr -> bigstring -> boff:int -> len:int -> off:int -> unit

(** Reserve blocks, falling back to setting the size; size 0 is a no-op. *)
val reserve : Unix.file_descr -> int -> unit

(** Bytes: [available] to this user, [free] including the reserve, [total]. *)
type space = { available : int64; free : int64; total : int64 }

(** [None] when unknown. *)
val disk_space : string -> space option

(** A BSD lock; [false] when [block] is false and the lock is held. *)
val flock : ?exclusive:bool -> ?block:bool -> Unix.file_descr -> bool

val funlock : Unix.file_descr -> unit

(** A process's claim on a role, held for its life: the exclusive lock of a file
    in a directory of this user, on a close-on-exec descriptor, so only the
    holder's exit releases it and no child inherits it. [None] when another
    process holds it. *)
val lifetime_lock : string -> Unix.file_descr option

(** A write to a closed socket fails with EPIPE instead of killing the process;
    every process that writes to peers calls it. *)
val ignore_sigpipe : unit -> unit

(** Copy-on-write clone into a new file. *)
val clone : string -> string -> unit

(** A missing path answers for its nearest existing ancestor; any other failure
    answers true, so a store that cannot be told is treated as shared. *)
val is_network_fs : string -> bool

(** Built for macOS. *)
val is_macos : bool

(** Whether a connected Unix socket's peer runs as this process's user, from the
    kernel. *)
val peer_same_user : Unix.file_descr -> bool

(** Raises the soft descriptor limit toward the hard one, capped at the target
    and never lowered; the soft limit in force. *)
val raise_nofile : int -> int

(** Open for reading without following a final symbolic link (ELOOP); [None]
    when absent. *)
val open_nofollow : string -> Unix.file_descr option

(** A private read-only mapping of a file never modified in place. *)
val map_file : string -> bigstring

(** The same, of an open descriptor. *)
val map_fd : Unix.file_descr -> bigstring

(** [len] bytes from [off] of a file never modified in place, which must hold
    them. *)
val map_range : Unix.file_descr -> off:int -> len:int -> bigstring

(** After a body read with {!map_fd} has been used: its pages leave this
    process's resident set, a later read paging them back in from the file. A
    body that is not a mapping is left alone. The collector unmaps a mapping
    only when it finalizes it, and does not count its size. *)
val drop_mapped_pages : bigstring -> unit

(** The whole file by positioned reads: for data that may change or vanish under
    a mapping (network mounts, files tsync does not own). *)
val read_fd_bigstring : Unix.file_descr -> bigstring

(** Remove temporaries in [dir] whose owner is dead, or older than [older_than]
    seconds when they name no owner. *)
val sweep_temps : ?older_than:float -> string -> unit

(** A plain, non-durable write for tests and fixtures. *)
val write_file_for_test : string -> string -> unit

(** The width of the terminal behind [fd]; [None] when it is not one. *)
val terminal_columns : Unix.file_descr -> int option

(** An absolute path without empty or [.] segments, its parent resolved and its
    last segment left as is: a dead mount there answers ENOTCONN. *)
val resolve_parent : string -> string

(** Flushes the filesystem holding [dir], when it exists: many replaced files
    made durable at once. *)
val syncfs : string -> unit
