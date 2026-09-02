(** The journal entries this client has already handled, kept where it can read
    them back.

    Not a second journal and not a second cursor. These are the entries
    {!File_store} publishes and applies, under the {!Journal.Entry_key} that
    already names one from the write-ahead record through the published object
    to the cursor a peer compares against. What is new is only that they are
    kept: a WAL record is dropped the moment its entry is published, and a
    peer's entry once it is applied, so answering "what changed since" meant
    fetching back from the store what this client held minutes ago.

    A sequence in the order entries were handled, month-sharded by that time,
    which is also the unit retention drops. Not by the month in the key: a
    peer's entry can be handled after entries whose keys are newer, and a reader
    is given what follows its anchor in this order, whatever the keys say. *)

(** How many days of handled entries are kept: the horizon behind which a store
    entry can no longer be told from one handled and since forgotten. *)
val keep_days : int

(** Keep [ops] under [entry_key].

    Called once the entry is published (this client's) or applied (a peer's), so
    a reader never meets an entry the mirror has not caught up with — which is
    exactly what reading the published journal cannot promise, and why answering
    from it needs a "the folder is not here yet" reply.

    One appended line, so whoever converges the domain and a CLI invocation may
    both write while a third process reads. Records are newline-led rather than
    newline-terminated, so a torn write is closed by the next one and costs only
    itself; the reader skips what will not parse rather than failing on it.

    [now] is when the entry was handled, a parameter only so a test can cross a
    shard boundary without waiting for the calendar.

    ponytail: no lock. Add a per-file one only if two writers ever tear more
    than the record between them. *)
val note :
  ?now:float ->
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

(** Entries handled after [since], exclusive, in that order; [None] starts at
    the oldest kept. Answers [None] when [since] is no longer kept, which is the
    whole of the staleness test: no delta bridges an anchor that is gone. *)
val since :
  cache_root:string ->
  domain_name:string ->
  ?since:Journal.Entry_key.t ->
  limit:int ->
  unit ->
  page option Lwt.t

(** The entry handled last, [None] before there is one. Reads the tail of one
    shard, so it stays cheap enough for the caller that asks before every
    enumeration. *)
val head :
  cache_root:string -> domain_name:string -> Journal.Entry_key.t option Lwt.t

(** Every key kept, for a reader deciding which of a store's entries it has
    already handled. *)
val keys :
  cache_root:string -> domain_name:string -> Journal.Entry_key.t list Lwt.t

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
