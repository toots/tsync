type file_entry = {
  key : Stored_key.t;
  size : int;
  last_modified : float;
  etag : string option;
      (** What the store calls this object's version, when it has a name for
          one: an S3 or GCS listing carries it, a filesystem has none.

          The only validator worth caching an object's body against. Size and
          [last_modified] are not: S3 reports whole seconds, and a manifest
          rewritten inside one to a body of the same length — same name, same
          chunk count — is invisible in both. *)
}

(** {1 What a store can say about a domain}

    One record rather than a method each: a composite merges them once, and
    adding a capability is a field here instead of an edit to every driver and
    every composite.

    A preference is [None] for a store with no opinion; a capability is a plain
    [bool], having no gap between "no opinion" and "cannot". *)
type caps = {
  share_url : string option;
      (** The share base URL, if this store serves shares for the domain. s3 and
          gcs answer with their configured [shareUrl]; http-proxy asks the
          frontend. *)
  chunk_size : int option;
      (** The chunk size this store recommends for new files. An http-proxy
          answers with the serving domain's own setting, so a client behind one
          inherits it instead of the value being mirrored in two configs.
          Consulted only when the client's own config is silent. *)
  max_concurrency : int option;
      (** How many object reads or writes this store can usefully serve at once,
          so a frontend taking work from many clients holds requests instead of
          handing them all to storage. A local store answers from the device
          under it; an http-proxy asks its peer. *)
  verified : bool;
      (** Whether every chunk this store takes is held against its own name
          ({!Corruption}): a [local] store as it writes unless that was turned
          off, an s3 or gcs store in the function its bucket's object-created
          event triggers.

          Reported rather than merely used, because a store that looked and
          found nothing and a store that never looked both list zero markers. *)
}

(** What {!S.list_many} answers for one folder: its listing whole, and a body
    for each child object in it. *)
type children = {
  listed : file_entry list;
  bodies : (Stored_key.t * Bigstring.t option) list;
}

module type S = sig
  type 'a io

  val put : key:Stored_key.t -> data:Bigstring.t -> unit -> unit io
  val get : key:Stored_key.t -> unit -> Bigstring.t io

  (** [None] when the key does not exist; other failures raise. Saves the HEAD
      round trip of [head_opt] + [get] when the body is wanted. *)
  val get_opt : key:Stored_key.t -> unit -> Bigstring.t option io

  (** [length] bytes of the object at [key], from [offset]. Every store has a
      native one — a range header, or a read at an offset — so this is a plain
      member rather than a declaration a resolver fills in: the generic form
      would be a whole [get] and a copy, which satisfies every caller while
      fetching what the range exists to avoid.

      What a store owes here:

      - exactly [length] bytes, which must be positive, and fewer only where the
        object ends. More than that means the store ignored the range, which is
        a failure rather than something to trim: a store answering whole objects
        would otherwise be indistinguishable from one answering ranges.
      - [None] for a key it does not hold, other failures raised. The [get_opt]
        shape rather than [get]'s, because the caller walks several keys and has
        to tell "not under this name" from "the link is down" — see
        {!Collection}, which is where the miss becomes a failure. *)
  val get_range :
    key:Stored_key.t ->
    offset:int ->
    length:int ->
    unit ->
    Bigstring.t option io

  (** Write [data] at [key] only if nothing is there, answering with whatever is
      there afterwards — [data] itself when this call won, the other writer's
      body when it did not.

      For a key that names a claim rather than content, where several clients
      may reach for it at once and exactly one must win: {!put} is
      last-writer-wins, so the loser's work would be stranded with nothing
      saying so.

      A claim is the only thing this is for — content is either
      content-addressed, in which case racing writers agree, or owned by one
      client. *)
  val put_if_absent :
    key:Stored_key.t -> data:Bigstring.t -> unit -> Bigstring.t io

  val head_opt : key:Stored_key.t -> unit -> file_entry option io

  (** Delete one key, answering whether an object was there. A caller moving a
      folder marker needs the answer: a delete that removed nothing is a marker
      left where it was, and a silent one is how a folder ends up at two paths.
      A caller collecting chunks does not, and uses {!delete_multi}. *)
  val delete : key:Stored_key.t -> unit -> bool io

  (** Delete every key, or raise. Two things callers depend on and every driver
      owes them:

      - a key that is not there is not a failure. {!Gc} sends every copy the
        same list whether or not it holds each one, and a resumed run repeats a
        batch it may already have deleted.
      - a list longer than whatever the store takes per request is still deleted
        whole; the driver pages.

      Bulk deletes are the awkward case, because a store answers one of these
      with a [200] carrying a per-key failure list. A driver that reads only the
      status reports success over keys that are still there — and nothing walks
      a copy afterwards to notice. See {!absent_code}. *)
  val delete_multi : Stored_key.t list -> unit io

  val copy : src_key:Stored_key.t -> dst_key:Stored_key.t -> unit -> unit io
  val list_prefix : ?max_keys:int -> prefix:string -> unit -> file_entry list io

  (** Return when the object at [key] may have changed, or after however long
      this store thinks is sensible to wait before saying so.

      A hint, never a guarantee: waking early is allowed and waking late is not,
      the caller re-reading and comparing either way — so a store with nothing
      native sleeps and returns, and one that can only watch something coarser
      than [key] may watch that and wake for its neighbours too. Bounded always,
      since a watch that cannot fire has to slow a caller down rather than stop
      it: that is what keeps a filesystem on a network mount, where an event
      never arrives for a remote writer, syncing at all.

      [last_seen] is what the caller last had at [key], so a store able to
      compare cheaply answers at once when its own differs rather than holding
      through a change that already happened. [None] from a caller that has
      never had one. *)
  val watch :
    key:Stored_key.t -> last_seen:Watch_token.t option -> unit -> unit io

  (** A native multi-object read, or [None] from a store with none — which is
      every store but http-proxy, S3 having no multi-object GET and the GCS
      batch API carrying metadata only.

      Declared rather than implemented, so a store without one says so and
      {!Batched} supplies the fan-out. A driver spelling its own would be
      choosing a width from inside a driver, which cannot see what else shares
      the process, and four drivers would then have four of them.

      Entries rather than bare keys as {!delete_multi} takes: a read has an
      answer to hold, so whoever packs a request needs the sizes, and a caller
      with a batch to make has just listed them.

      What a store declaring one owes its callers:

      - every key asked for is answered exactly once, in the order asked;
      - an absent key is answered [None], not a failure;
      - a list longer than the store takes per request is still answered whole;
        the driver pages.
      - a per-key failure is raised rather than answered [None]. This is
        {!absent_code}'s lesson for reads: a caller told a key is absent writes
        a mirror missing that file, and nothing walks it afterwards to notice.
  *)
  val get_many :
    (entries:file_entry list ->
    unit ->
    (Stored_key.t * Bigstring.t option) list io)
    option

  (** A folder's listing with the bodies of its child objects, for many folders
      in one request, or [None] from a store with none. Answered in request
      order; a folder the store left out, for a byte budget it alone knows, is
      the caller's to ask for singly. Every store but http-proxy answers [None]:
      only a peer holding the objects can list and read in one act. *)
  val list_many :
    (prefixes:string list -> unit -> (string * children) list io) option

  (** Ask the store to check every chunk it holds against its own name and file
      what fails under {!Chunk_layout.corrupted_prefix}, answering how many
      units of work were queued rather than what they found.

      A store with nothing on its side to run one — a filesystem has no event
      source, an http-proxy peer owns its own store — answers [`Unsupported] so
      the caller can fail rather than report a check that never happened; a
      filesystem's own sweep is [tsync gc --verify]. *)
  val verify_all :
    chunk_prefix:string -> unit -> [ `Queued of int | `Unsupported ] io

  (** Hand a collection's unreferenced chunks to whatever this store has on its
      side to delete them, rather than deleting them from here. Answers
      [`Queued] having written a request its bucket's own notification delivers
      — the function drops the chunks and derives the markers naming them, so
      {!Gc} sends only the chunk keys.

      [`Unsupported] from a store with no such function, which is every store
      unless its bucket was deployed with one; {!Gc} then falls back to
      {!delete_multi} and nothing about the collection changes. The gap between
      "no opinion" and "cannot" matters more here than for {!verify_all}: a
      store wrongly claiming this would leave keys on a copy for good, since
      nothing walks a copy's own shards afterwards.

      What lets {!Gc} discard the main straight after [`Queued] is that the
      request is durably stored before this returns. Awaited, never detached — a
      request that had not landed yet would put the collection back to deleting
      the evidence before recording the instruction.

      [run] and [name] identify the batch: {!Gc} passes the collection it
      belongs to and the cursor it is about to save, so a re-run of an
      interrupted flush overwrites its own request while a later collection
      cannot overwrite one this collection left behind. *)
  val discard :
    chunk_prefix:string ->
    run:string ->
    name:string ->
    keys:Stored_key.t list ->
    unit ->
    [ `Queued | `Unsupported ] io

  (** What this store can tell a client about [prefix]'s domain. [prefix]
      identifies the domain, for backends that front several. *)
  val capabilities : prefix:string -> unit -> caps io

  (** Whether a read from this store is cheap enough that taking more than was
      asked for is the better trade. True for a filesystem on this machine,
      where a whole cache chunk costs about what a range of it does and leaves
      the reads after this one with nothing to fetch at all; false wherever a
      read crosses a link, and a range is the difference between a few bytes and
      a few megabytes.

      Not derived from {!local_path}: that grants the filesystem, and a caller
      handed a tree may want it for reasons that have nothing to do with what a
      read costs — a composite has no one tree and still reads through one
      store. *)
  val fast_read : bool

  (** The directory this store keeps its objects in, where the object for a key
      is the file at that path under it. [None] for a store to be reached only
      through the operations above.

      What it grants is the filesystem: a caller may read, rename and remove
      within the tree. Nothing here says what anyone does with that — a
      collection renames the chunk root aside and renames chunks back
      ({!Collection}), and a report only wants a path to measure. *)
  val local_path : string option

  (** Whether the store's link is there, as its own requests have found it: what
      a caller with somewhere else to read from asks first. A store with no link
      to lose answers {!Health.always_up}. *)
  val health : Health.t
end
