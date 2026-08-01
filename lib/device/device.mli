(** What the storage under a path will usefully take at once.

    A store that accepts every request it is handed does not go faster than the
    device beneath it; past that point the requests queue somewhere less useful
    than a queue built for them, and the work already accepted finishes later
    than if less had been accepted. So whoever accepts work from many clients at
    once needs a figure to hold them against, and only the platform can say what
    it is: a USB enclosure speaking Bulk-Only Transport takes one command at a
    time, an NVMe drive takes hundreds, and nothing about the path says which.
*)

(** [max_concurrency path] is how many object reads or writes the device holding
    [path] can usefully be serving at once, or [None] when this platform cannot
    tell — in which case the caller should fall back to its own default rather
    than assume either extreme.

    Requests, not commands: one object read becomes many commands, which the
    kernel merges and reorders, so the useful figure is a small multiple of what
    the hardware reports rather than the number itself.

    May cost a syscall or a subprocess, so callers should ask once per store
    rather than once per request. *)
val max_concurrency : string -> int option
