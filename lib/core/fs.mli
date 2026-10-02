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
val exists : string -> bool
val is_dir : string -> bool

(** The kind of what is at a path, without following a link. *)
val kind : string -> [ `Absent | `Dir | `File | `Link | `Other ]

val openfile : ?perm:int -> string -> Unix.open_flag list -> Unix.file_descr
val close : Unix.file_descr -> unit
val with_fd : Unix.file_descr -> (Unix.file_descr -> 'a) -> 'a
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

(** Remove a tree without following symbolic links. *)
val rm_rf : string -> unit

val rename : ?op:string -> string -> string -> unit

(** EEXIST when the target exists. *)
val rename_noreplace : string -> string -> unit

val link : string -> string -> unit

(** A fresh temporary name in [dir]. *)
val temp_in : string -> string

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

(** A write to a closed socket fails with EPIPE instead of killing the process;
    every process that writes to peers calls it. *)
val ignore_sigpipe : unit -> unit

(** Copy-on-write clone into a new file. *)
val clone : string -> string -> unit

val is_network_fs : string -> bool

(** Built for macOS. *)
val is_macos : bool

(** The uid of a connected Unix socket's peer, from the kernel. *)
val peer_uid : Unix.file_descr -> int

(** Raises the soft descriptor limit toward the hard one, capped at the target
    and never lowered; the soft limit in force. *)
val raise_nofile : int -> int

val pid_alive : int -> bool

(** Open for reading without following a final symbolic link (ELOOP); [None]
    when absent. *)
val open_nofollow : string -> Unix.file_descr option

(** A private read-only mapping of a file never modified in place. *)
val map_file : string -> bigstring

(** The same, of an open descriptor. *)
val map_fd : Unix.file_descr -> bigstring

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
