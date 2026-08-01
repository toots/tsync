(** What the storage under a path will usefully take at once.

    Accepting every request handed over does not make the device faster: past
    its limit the requests queue somewhere worse than a queue built for them,
    and the work already accepted finishes later. So a frontend taking work from
    many clients needs a figure to hold them against, and only the platform can
    say what it is — a USB enclosure on Bulk-Only Transport takes one command at
    a time, an NVMe drive hundreds, and nothing about the path says which. *)

(** How many object reads or writes the device holding [path] can usefully serve
    at once, or [None] when the platform cannot tell — in which case the caller
    falls back to its own default rather than assuming either extreme.

    Requests, not commands: one object read becomes many commands, which the
    kernel merges and reorders, so the useful figure is a small multiple of what
    the hardware reports.

    May cost a syscall or a subprocess: ask once per store, not per request. *)
val max_concurrency : string -> int option
