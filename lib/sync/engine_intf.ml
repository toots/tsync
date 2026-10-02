(** The signature of a domain's engine; see {!Engine}. *)

open Tsync_core
open Tsync_checkout

(** What the status report reads of an engine (07 §5.5). *)
type activity = {
  intent : int;
  prepared : int;
  executed : int;
  stuck : int;  (** parked records: retried only on {!S.rearm} *)
  last_error : string option;
  in_flight : string list;  (** paths of the uploads running now *)
  bytes_owed : int;  (** whole-file bytes of every unpublished put *)
  mark_age : float option;  (** seconds since the last-sync mark's entry *)
  cache : Cache.counts;
  max_cache : int option;
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

  (** The content identity [h1] of what a key resolves to, when known. *)
  val content_id : string -> string option

  val availability : string -> [ `Online_only | `Cached | `Pinned of float ]

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

  (** Adopt a complete file by rename, then close. *)
  val write_whole :
    string ->
    src:string ->
    ?base:string ->
    exclusive:bool ->
    unit ->
    Staged.edit

  val sync : string -> unit

  (** After a modification: sync, then a durable upload record. *)
  val close : string -> unit

  val delete : string -> unit
  val mkdir : string -> exclusive:bool -> unit
  val rmdir : string -> unit
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

  (** Local recovery, reconcile, the queues and the copy logs, then the journal
      poller unless [poll_journal] is false. *)
  val start : ?poll_journal:bool -> unit -> unit

  (** Metadata, then uploads, then the cursor flush and the copies, within the
      grace; what is left stays owed on disk. *)
  val drain : ?grace:float -> unit -> unit

  (** Bring the trashed folder whose trash entry records [path] back at [path]
      (05 §4.8): placed on the store, then the folder and every folder and file
      beneath it announced; how many. UNPREPARED when this client has not
      resolved the parent folder. *)
  val restore_from_trash :
    string -> [ `Restored of int | `Not_in_trash | `Exists ]

  (** Bring the content of a local directory into the domain at the same
      relative paths (05 §4.3): folders claimed and announced first, then files
      uploaded and announced in batches; what exists is skipped unless
      [force_rehash]. *)
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

  (** Adopt records other processes submitted, then run a journal pass soon. *)
  val poll : unit -> unit

  (** Evicts down to the cache cap (04 §4.11), as housekeeping does on every
      pass: a host that mostly reads uploads nothing that would. *)
  val trim_cache : unit -> unit

  (** One discovery-and-application pass; the number of entries applied. *)
  val apply_pass : unit -> int

  (** A full rebuild from the store's tree: manifests walked and failures. *)
  val rebuild : ?narrate:Narrate.t -> ?parallelism:int -> unit -> int * int

  (** One pass, or a rebuild when [full] or when the client cannot bridge
      (manifests walked and failures). *)
  val resync :
    ?narrate:Narrate.t ->
    ?full:bool ->
    ?parallelism:int ->
    unit ->
    [ `Incremental of int | `Full of int * int ]

  val set_paused : bool -> unit
  val is_paused : unit -> bool
  val bridge : unit -> Outbound.bridge

  (** Stepped-aside peer entries with their reason. *)
  val unapplied : unit -> (string * string) list

  val pending_uploads : unit -> int

  (** Reads every WAL record: meant for a report, not a hot path. *)
  val activity : unit -> activity

  val pending_metadata : unit -> int
  val parked : unit -> (string * Dqueue.failure_note) list

  (** Re-adopt every parked record; how many. *)
  val rearm : unit -> int

  (** Called with the paths the owner changed behind its frontends. *)
  val set_changed_hook : (string list -> unit) -> unit

  val applied : Applied.t

  (** The resync generation stamp, [""] when never stamped. *)
  val resync_generation : unit -> string

  val stamp_generation : unit -> unit
  val mirror : Mirror.t
  val staged_edits : unit -> (string * Staged.edit) list
end
