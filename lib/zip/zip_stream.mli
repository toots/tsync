(** Streaming ZIP64 archive writer, STORED (no compression).

    Emits only the archive's *framing* bytes and tracks the state needed for the
    central directory; the caller writes member payloads itself. Nothing is
    buffered beyond the directory, so an archive of any size streams straight to
    a socket without ever existing in memory or on disk.

    Sizes are unknown when a member starts (the payload is streamed), so members
    carry their CRC and sizes in a trailing data descriptor (general-purpose bit
    3) and every archive is written as ZIP64 — hence no 4 GiB ceiling on members
    or on the archive.

    Usage per member: {!start_entry}, then {!feed} for each payload block (the
    caller writes those blocks), then {!end_entry}. {!finish} closes the
    archive. *)

type t

val create : unit -> t

(** Local file header for a member. [mtime] is a Unix timestamp; [mode] is the
    Unix permission bits recorded in the archive (default [0o644]). *)
val start_entry : t -> name:string -> mtime:float -> ?mode:int -> unit -> string

(** Record a directory member. Emits its header and closes it immediately: a
    directory has no payload, so no {!feed}/{!end_entry} is needed. A trailing
    "/" is added to [name] when absent. *)
val add_directory : t -> name:string -> mtime:float -> string

(** Account for one block of the current member's payload. The caller is
    responsible for writing [block] to the output; this only advances the CRC
    and byte count. *)
val feed : t -> string -> unit

(** Data descriptor closing the current member. *)
val end_entry : t -> string

(** Central directory, ZIP64 end-of-central-directory record, ZIP64 locator and
    the end-of-central-directory record. *)
val finish : t -> string
