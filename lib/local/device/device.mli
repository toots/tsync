(** What the storage under a path will usefully take at once.

    Past its limit the requests queue somewhere worse than a queue built for
    them, and only the platform can say where that limit is — a USB enclosure on
    Bulk-Only Transport takes one command at a time, an NVMe drive hundreds, and
    nothing about the path says which. *)

(** How many object reads or writes the device holding [path] can usefully serve
    at once, or [None] when the platform cannot tell — in which case the caller
    falls back to its own default rather than assuming either extreme.

    Requests, not commands: one object read becomes many commands, which the
    kernel merges and reorders, so the useful figure is a small multiple of what
    the hardware reports. May cost a syscall or a subprocess: ask once per
    store, not per request. *)
val max_concurrency : string -> int option

(** A read-only descriptor on a copy-on-write clone of [src], already unlinked:
    it duplicates references to the source's blocks rather than the blocks, so
    it costs no space and no time proportional to the file, nothing written to
    [src] afterwards reaches it, and no name is left for a kill to leak or a
    directory walker to find.

    [None] where the filesystem cannot clone — APFS and btrfs can, XFS can when
    made with [reflink=1], ext4 and tmpfs cannot — which is the caller's cue to
    read the file itself, whereas a directory that will not take the clone at
    all raises [Unix_error]. The caller closes it. *)
val clone : src:string -> Unix.file_descr option
