(** The journal entries this client has already handled, kept where it can read
    them back.

    Not a second journal and not a second cursor. These are the entries
    {!File_store} publishes and applies, under the {!Journal.Entry_key} that
    already names one from the write-ahead record through the published object
    to the cursor a peer compares against. What is new is only that they are
    kept: a WAL record is dropped the moment its entry is published, and a
    peer's entry once it is applied, so answering "what changed since" meant
    fetching back from the store what this client held minutes ago.

    Month-sharded as the published journal is
    ({!Journal.Entry_key
    .relative_path}), which is also the unit retention
    drops. *)

(** Keep [ops] under [entry_key].

    Called once the entry is published (this client's) or applied (a peer's), so
    a reader never meets an entry the mirror has not caught up with — which is
    exactly what reading the published journal cannot promise, and why answering
    from it needs a "the folder is not here yet" reply.

    One appended line, so whoever converges the domain and a CLI invocation may
    both write while a third process reads. Records are newline-led rather than
    newline-terminated, so a torn write is closed by the next one and costs only
    itself; the reader skips what will not parse rather than failing on it.

    ponytail: no lock. Add a per-file one only if two writers ever tear more
    than the record between them. *)
val note :
  cache_root:string ->
  domain_name:string ->
  Journal.Entry_key.t ->
  Journal.op list ->
  unit Lwt.t

type page = {
  entries : (Journal.Entry_key.t * Journal.op list) list;
      (** Oldest first, at most [limit] of them. *)
  more : bool;
      (** Another call anchored at the last entry would answer with something,
          so a caller reporting in batches knows to come back. *)
}

(** Entries after [since], exclusive, oldest first. [None] starts at the oldest
    kept. *)
val since :
  cache_root:string ->
  domain_name:string ->
  ?since:Journal.Entry_key.t ->
  limit:int ->
  unit ->
  page Lwt.t

(** The newest entry kept, [None] before there is one. Reads the tail of one
    shard, so it stays cheap enough for the caller that asks before every
    enumeration. *)
val head :
  cache_root:string -> domain_name:string -> Journal.Entry_key.t option Lwt.t

(** The oldest entry kept. An anchor older than this cannot be bridged, which is
    the whole of the staleness test — {!Journal.Entry_key.cannot_bridge} asks
    the same question of the published journal. *)
val oldest :
  cache_root:string -> domain_name:string -> Journal.Entry_key.t option Lwt.t

(** Drop whole shards once they are older than [keep_days], and oldest-first
    while what is left exceeds [keep_bytes]. Answers with how many shards went
    and how many bytes they held.

    Bytes rather than a count of entries: a shard's size is one stat where a
    count is a full read, and both bound the same thing. A shard is kept whole
    or not at all, so the window is the stated one rounded up to a month. *)
val prune :
  cache_root:string ->
  domain_name:string ->
  keep_days:int ->
  keep_bytes:int ->
  (int * int) Lwt.t
