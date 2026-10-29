(** The signature of a domain's engine; see {!Engine}. *)

open Tsync_core
open Tsync_checkout

(** A transfer running now (08 §3.3 status): [bytes] of [size] moved since
    [started] (wall time). *)
type transfer = Local_ops.transfer = {
  path : string;
  size : int;
  bytes : int;
  started : float;
}

(** What the status report reads of an engine (07 §5.5, 03 §3.4). *)
type activity = {
  position : int option;  (** the last entry merged *)
  pending : int;  (** keys with a before-value *)
  pushing : bool;  (** an in-flight record exists *)
  tree_head : int;  (** as last read, below 0 until it was *)
  unfollowed : (int * string) option;
      (** an entry this client cannot follow, and why *)
  failing : string option;
      (** why the last background cycle failed, until one runs again *)
  damaged : string list;
      (** files whose content the main lacks and this client cannot send again
      *)
  stuck : int;  (** parked uploads: retried only on {!S.rearm} *)
  retrying : int;  (** uploads whose last attempt failed, retried on backoff *)
  set_aside : int;
      (** records and staged manifests set aside: never run, kept until a user
          removes them (durable-queue §6) *)
  last_error : string option;
  uploading : string list;  (** paths of the uploads running now *)
  bytes_owed : int;  (** whole-file bytes of every edit not uploaded yet *)
  cache : Cache.counts;
  max_cache : int option;
}

(** What a sync did (05 §4.7): the entries merged, or the file records and
    folders a state read found; the paths the merge changed; the entries this
    client created; the commands still pending. *)
type synced = {
  arrival : [ `Entries of int | `State of int * int ];
  changed : int;
  committed : int;
  pending : int;
}

module type S = sig
  (** Holds the metadata lock across [f]; every operation called inside joins
      the same hold. *)
  val atomically : (unit -> 'a) -> 'a

  val kind : string -> [ `Dir | `File | `Absent ]

  (** Answered from the mirror; a staged edit's size and mtime win. *)
  val stat : string -> Local_ops.stat

  type entry = { name : string; is_dir : bool; st : Local_ops.stat }

  (** Real names, bytewise order; a staged-only file is listed. *)
  val list_children : string -> entry list

  val list_tree : string -> (string * Local_ops.stat) list
  val readlink : string -> string
  val availability : string -> [ `Online_only | `Cached | `Pinned of float ]

  (** Cache groups of a file whole on this machine, and its groups. *)
  val residency : string -> int * int

  (** The folder id held at a path; never mints. *)
  val folder_id : string -> Folder_id.t option

  val path_of_id : Folder_id.t -> string option

  type handle = Local_ops.handle

  (** Bound to the key's lineage (04 §3.3). *)
  val open_read : string -> handle

  (** Short only at the end of the content; DEADLINE past the read deadline. *)
  val read : handle -> off:int -> len:int -> Bigstring.t

  val close_read : handle -> unit

  (** The content as it is now, readable after an unlink or a replace. *)
  val retain : string -> handle

  val release : handle -> unit
  val write : string -> off:int -> Bigstring.t -> unit
  val truncate : string -> int -> unit
  val create : string -> exclusive:bool -> unit

  (** Adopt a complete file by rename, then close; staged aside when [base] is
      not the key's current content, nothing when the content is the same. The
      path that holds what was written. *)
  val write_whole :
    string -> src:string -> ?base:string -> exclusive:bool -> unit -> string

  (** The symlink policy in force: the main's where it states one (05 §2.1). *)
  val symlinks : unit -> [ `Keep | `Follow | `Skip ]

  (** Returns once the key's change is committed or its upload started failing
      (08 §3.5 [write] with [await]), or the domain is paused. *)
  val await_upload : string -> unit

  val sync : string -> unit

  (** After a modification: sync, then a durable upload record. *)
  val close : string -> unit

  val delete : string -> unit
  val mkdir : string -> exclusive:bool -> unit
  val rmdir : string -> unit

  (** The folder and everything beneath it, as one local operation per item (04
      §4.5). *)
  val remove_tree : string -> unit

  val rename : src:string -> dst:string -> exclusive:bool -> unit
  val symlink : string -> target:string -> exclusive:bool -> unit
  val evict : string -> unit

  (** Pin until [now + keep] seconds, then fetch whole. *)
  val pin : string -> keep:float -> unit

  val unpin : string -> unit

  (** The whole content into a new file, created exclusively. *)
  val assemble_to : string -> string -> unit

  (** Bytes [\[off, off + len)] at their offset in a new file; the served
      length. *)
  val fetch_range : string -> string -> off:int -> len:int -> int

  (** Local recovery, the upload queue and the copy logs, then the background
      cycle unless [background] is false. On a lazy tree the cycle only pushes.
  *)
  val start : ?background:bool -> unit -> unit

  (** Uploads, a last cycle, the cursor flush and the copies, within the grace;
      what is left stays owed on disk. *)
  val drain : ?grace:float -> unit -> unit

  (** 04 §4.6: put a saved version of the file at [path] back, the newest when
      [version] (its timestamp in ns) is none. The current content is saved as a
      version first. ABSENT when no such version; needs versioning. *)
  val revert : ?version:int64 -> string -> unit

  (** Bring the content of a local directory into the domain at the same
      relative paths (05 §4.3), as local operations, and return once they are
      committed; what exists is skipped unless [force_rehash]. *)
  val import :
    ?narrate:Narrate.t ->
    ?cancelled:(unit -> bool) ->
    ?only:string list ->
    ?exclude:string list ->
    ?force_rehash:bool ->
    string ->
    Import_plan.report

  (** Copy or move between a local path and the domain, or within the domain (05
      §4.5): every entry decided from fresh facts, then folders, domain writes,
      local writes, moves within the domain, and on a move the sources dropped.
      [dry_run] decides only. *)
  val rsync :
    ?narrate:Narrate.t ->
    ?cancelled:(unit -> bool) ->
    ?move:bool ->
    ?dry_run:bool ->
    src:Rsync_plan.endpoint ->
    dst:Rsync_plan.endpoint ->
    unit ->
    Rsync_plan.report

  (** Run a cycle now. *)
  val poll : unit -> unit

  (** A cycle now, pushing only what is due: there is an entry to project. *)
  val nudge : unit -> unit

  (** Evicts down to the cache cap (04 §4.11), as housekeeping does on every
      pass: a host that mostly reads uploads nothing that would. *)
  val trim_cache : unit -> unit

  (** One cycle now, its arrival by state when [full] (05 §4.7). Refused while
      paused and on a lazy tree. *)
  val resync : ?narrate:Narrate.t -> ?full:bool -> unit -> synced

  val set_paused : bool -> unit
  val is_paused : unit -> bool

  (** The domain-wide settings the main states, once learned (05 §2.1); [wait]
      asks the main now when they are not learned yet. *)
  val stated_settings :
    ?wait:bool -> unit -> Tsync_store.Store.domain_settings option

  val pending_uploads : unit -> int

  (** The keys changed here and not committed yet. *)
  val pending_changes : unit -> int

  (** Why the last cycle failed, until one runs. *)
  val failing : unit -> string option

  (** The uploads running now; cheap: reads only their records. *)
  val uploads : unit -> transfer list

  (** Every transfer of a file's bytes from the store running now: a fetch, a
      range, a restore. *)
  val downloads : unit -> transfer list

  (** Reads the staged tree: meant for a report, not a hot path. *)
  val activity : unit -> activity

  val parked : unit -> (string * Dqueue.failure_note) list

  (** Re-adopt every parked record; how many. *)
  val rearm : unit -> int

  (** Called with the paths the owner changed behind its frontends. *)
  val set_changed_hook : (string list -> unit) -> unit

  val applied : Applied.t

  (** Stamps a new generation and clears the feed watermark (08 §3.6). *)
  val stamp_generation : unit -> unit

  (** The current change anchor [<generation>|<feed key>]; sets the feed
      watermark when none exists (08 §2.5, §3.6). *)
  val cursor : unit -> string

  (** 08 §3.6 steps 1–5: [`Page (cursor, more, ops)] after the anchor, the
      watermark moved to the anchor's key; [`Stale] for another generation, a
      line that is not kept, or an empty key once a shard was dropped. *)
  val changes_since :
    string -> limit:int -> [ `Stale | `Page of string * bool * Applied.op list ]

  (** Applied-log retention (03 §2.9); shards removed. *)
  val prune_applied : unit -> int

  (** The owner's daily sweep of local state: stale temporaries, and the records
      of folders removed longer ago than any entry can name. *)
  val daily_maintenance : unit -> unit

  (** The lazy tree (04 §3.5, publication §4.11): an arrival for one folder;
      whether its children changed. UNPREPARED for a folder with no id here; a
      failed pull changes nothing. Concurrent pulls of one folder share one
      read. *)
  val pull : string -> bool

  (** When the folder's last pull completed, by its pull marker (04 §2.3). *)
  val pulled_at : string -> float option

  (** Whether this client created the folder and has not published it: then the
      main holds nothing there that it lacks (publication §4.11). *)
  val created_here : string -> bool

  (** Until when the folder's view is answered whatever its age. *)
  val view_hold : string -> float option

  (** Raises the view hold of a folder and of every ancestor. *)
  val hold_views : string -> until:float -> unit

  (** Pulls the file's folder, so the file is at its current version (android
      §3.2 rule 3). *)
  val refresh_file : string -> unit

  val mirror : Mirror.t
end
