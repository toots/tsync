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
