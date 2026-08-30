(** File content as bytes, read per chunk out of {!Chunk_cache}.

    A file is never assembled: a read maps its byte range onto the chunks
    backing it, fetching only the ones that are absent. *)

(** What this needs below it. *)
module type FS = sig
  type 'a io
  type fd

  val zero : Bigstring.t -> pos:int -> len:int -> unit
  val pread : fd -> Bigstring.t -> file_offset:int -> int -> int -> int io
  val read : string -> Bigstring.t -> offset:int64 -> int io
  val write : string -> Bigstring.t -> offset:int64 -> int io
  val copy_file : src:string -> dst:string -> unit io
  val ensure_parent : string -> unit io
  val is_directory : string -> bool io
  val readdir_list : string -> string list io
  val read_file_opt : string -> string option io
  val atomic_write : string -> string -> unit io
  val reap_older_than : cutoff:float -> string -> bool io
  val unlink_quiet : string -> unit io

  val atomic_write_at :
    string ->
    size:int ->
    ((offset:int -> Bigstring.t -> unit io) -> unit io) ->
    unit io

  val real_dir_name : string -> string -> string io
end

module type SYSCALLS = sig
  type 'a io
  type fd

  val file_exists : string -> bool io
  val stat : string -> Unix.stats io
  val link : string -> string -> unit io
  val rename : string -> string -> unit io
  val utimes : string -> float -> float -> unit io
  val openfile : string -> Unix.open_flag list -> Unix.file_perm -> fd io
  val close : fd -> unit io

  module LargeFile : sig
    val stat : string -> Unix.LargeFile.stats io
    val ftruncate : fd -> int64 -> unit io
  end
end

module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val use : t -> (unit -> 'a io) -> 'a io
  val map_with : t -> ('a -> 'b io) -> 'a list -> 'b list io
  val iter_with : t -> ('a -> unit io) -> 'a list -> unit io
  val filter_map_with : t -> ('a -> 'b option io) -> 'a list -> 'b list io
end

module type LOCKS = sig
  type 'a io
  type mutex

  val mutex : unit -> mutex
  val with_lock : mutex -> (unit -> 'a io) -> 'a io
end

module type MIRROR = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val published : Logical_key.t -> Manifest.t option io
    val write : Logical_key.t -> Manifest.t -> unit io

    val current :
      Logical_key.t ->
      [ `Staged of Staged_manifest.staged * Manifest.t option
      | `Published of Manifest.t ]
      option
      io
  end
end

(** What this needs of the store above it. *)
module type REMOTE = sig
  type 'a io

  val chunk_size : unit -> int io
  val get_chunk : chunk_key:string -> Bigstring.t io

  val get_chunk_range :
    chunk_key:string -> offset:int -> length:int -> Bigstring.t io

  val fast_read : bool

  val upload :
    key:Logical_key.t ->
    src_path:string ->
    mtime:float ->
    chunk_size:int ->
    ?cancel:bool ref ->
    ?on_progress:(bytes:int -> sent:bool -> unit) ->
    unit ->
    Manifest.t io

  val upload_chunks :
    key:Logical_key.t ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:(int -> unit io Chunk_source.t io) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.t io

  val fetch_manifest : key:Logical_key.t -> unit -> Manifest.t option io
end

module Over
    (Io : Io.S)
    (Fs : FS with type 'a io := 'a Io.t)
    (_ : SYSCALLS with type 'a io := 'a Io.t and type fd = Fs.fd)
    (_ : LOCKS with type 'a io := 'a Io.t)
    (_ : POOLS with type 'a io := 'a Io.t)
    (_ : MIRROR with type 'a io := 'a Io.t) : sig
  module Make
      (C : Conf.S with type 'a io = 'a Io.t)
      (R : REMOTE with type 'a io := 'a Io.t) : sig
    (** Fills [buf] from [offset] in the file [manifest] describes, returning
        the byte count — short only at end of file. [id] is for the read-ahead
        heuristic alone. Raises {!Backend.Backend_error} for a manifest whose
        chunk list has a hole, rather than serving zeros as content. *)
    val pread :
      id:string ->
      ?stream:string ->
      manifest:Manifest.t ->
      Bigstring.t ->
      offset:int64 ->
      int Io.t

    (** [key]'s published manifest, read from the local mirror, which holds one
        sidecar per key the poller has replayed and is the whole answer: a name
        it does not carry is a name the domain does not have.

        Says nothing about staged edits: a staged key is by definition local, so
        a caller wanting those asks {!Checkout.current} first. {!File_ops.stat}
        is the composition of the two. *)
    val published : Logical_key.t -> Manifest.t option Io.t

    (** {!pread} for a key of this domain, resolved through
        {!Manifest.Make.resolve}: staged edits, else what was published. Reads
        nothing for a key the mirror does not hold. *)
    (** [stream] names the descriptor reading, so two open on one file each keep
        their own place for the read-ahead heuristic; without it they share one. *)
    val pread_key :
      ?stream:string -> Logical_key.t -> Bigstring.t -> offset:int64 -> int Io.t

    (** {2 Writes}

        Bytes reach disk before the staged manifest that references them, so a
        crash leaves at worst an unreferenced staged body — never a manifest
        pointing at bytes that were never written. *)

    (** Write [buf] at [offset], growing the file as needed. Returns the byte
        count. A write covering only part of an inherited chunk copies that
        chunk into a staged body first: content-addressed chunks are immutable.
    *)
    val write : Logical_key.t -> Bigstring.t -> offset:int64 -> int Io.t

    (** Resize: drop whole chunks past the end and resize the boundary chunk. A
        grow is pure metadata — the new chunks are holes reading as zeros. *)
    val truncate : Logical_key.t -> int64 -> unit Io.t

    (** Reset [key] to an empty staged file, dropping any staged bodies. *)
    val create : Logical_key.t -> unit Io.t

    (** Upload [key]'s staged edits and promote them. A staged body already
        holds its group's bytes in the group's layout, so promotion gives it the
        group's content name rather than copying it, then writes the published
        sidecar, then drops the staged manifest, and only then the staged name.
        No-op when nothing is staged.

        The order is what lets a reader run alongside: the key resolves to the
        staged manifest or the published one, and whichever it lands on names
        bytes that are on disk. Where the cache root cannot hold a second name
        for one inode the group is written out instead, which costs the copy but
        changes nothing else.

        Every step is idempotent, and the upload records what it published in
        the staged manifest before touching anything else: a crash before that
        point re-uploads identical bytes, one after replays only local moves. A
        write arriving in between retires that record, and the promotion is
        abandoned rather than publishing bytes the file no longer holds. *)
    val sync : Logical_key.t -> ?cancel:bool ref -> unit -> unit Io.t

    (** {2 Chunk store housekeeping}

        Routed through here so a domain has exactly one chunk store instance:
        two would each keep their own in-flight table and stop deduplicating
        each other's downloads. *)

    (** Delete chunk bodies, oldest first, while the store is over
        [C.max_cache]. Never touches staged bodies. *)
    val enforce_chunk_cap : unit -> unit Io.t

    (** [(chunks, bytes)] held locally. *)
    val chunk_stats : unit -> (int * int) Io.t

    val downloads_in_flight : unit -> int

    (** Whole files pulled in since start-up, by any route. *)
    val downloads_completed_count : unit -> int

    (** Stage a whole file handed over by a frontend as [key]'s new content,
        replacing anything staged before it. *)
    val stage_whole : Logical_key.t -> src_path:string -> unit Io.t

    (** [(chunks present locally, chunks total)] for [key]; [(0, 0)] when it has
        no manifest at all. Staged bodies count as present. *)
    val chunk_residency : Logical_key.t -> (int * int) Io.t

    (** Fetch every chunk [key] needs, so reads are served locally afterwards.
        Writes the sidecar first for a file that has no local metadata yet. *)
    val ensure_local : Logical_key.t -> unit Io.t

    (** Write [key]'s whole content to [dst_path] (mtime included) through the
        normal read path — for a caller that needs a real file: an export, or
        the copy handed to a frontend. *)
    val assemble_to : Logical_key.t -> dst_path:string -> unit Io.t

    (** Writes that range of [key] into [dst_path] at the same offset, leaving
        the rest sparse, and returns the byte count — short only at end of file.
        Only the chunks the range covers are fetched, so a large file is served
        a piece at a time. [dst_path] is created even for a range past the end.
    *)
    val fetch_range :
      Logical_key.t -> dst_path:string -> offset:int -> length:int -> int Io.t

    (** [Some (bytes_done, bytes_total)] while [key] is being pulled in whole;
        [None] otherwise. *)
    val download_progress : Logical_key.t -> (int * int) option

    (** One file being read whose chunks are coming off a backend right now.
        [bytes] is what this read has pulled, not what the file holds; [size] is
        the whole file, so a caller can say "12.4 MB of 1.2 GB" without touching
        the store. *)
    type pulling = {
      key : string;
      bytes : int;
      size : int;
      seconds : float;
      rate : float;  (** bytes per second, over a recent window *)
    }

    (** Files currently waiting on the network because something is reading them
        — distinct from {!download_progress}, which is whole-file
        materialization. Biggest first and capped, since [status] asks on every
        poll, and pruned of anything gone quiet as a side effect of asking.

        Synchronous on purpose: the table is mutated by reads on the same loop,
        so a fold that could yield would see it change underneath itself.

        Note that [Make] is applied once per consumer — {!Sync.File},
        {!Diagnostics}, the share server, {!Ops.Export} — and each gets its own
        table. Only the one behind [File_ops.S] is reachable over IPC, so a file
        served by the share server does not appear here. The same is already
        true of {!downloads_in_flight}.

        [now] overrides the clock the idle sweep reads, so a caller can ask what
        the table will look like later without waiting for it. *)
    val pulling_now : ?now:float -> unit -> pulling list

    (** Drop [key]'s cached chunks; they re-fetch on demand. Unreference-blind:
        a chunk shared with another file goes too. Staged bodies are untouched.
    *)
    val forget_chunks : Logical_key.t -> unit Io.t

    (** Drop [key]'s staged manifest and the bodies it names. *)
    val discard_staged : Logical_key.t -> unit Io.t

    (** Where a whole staged body sits on disk, for a reader that wants the
        bytes an upload is sending. [None] once chunked, or for an unstaged key.
    *)
    val staged_body_path : Logical_key.t -> string option Io.t

    (** Delete staged bodies no staged manifest names, and prune the empty
        directories left in the staged manifest tree.

        Once per machine, before anything serves: staging creates a body before
        the manifest that names it, so mid-session an unreferenced body is
        indistinguishable from one a write is about to use. *)
    val reclaim_staged_orphans : unit -> unit Io.t
  end
end
