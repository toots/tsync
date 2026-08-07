(** Streaming ZIP64 archive writer, STORED (no compression).

    Emits only the archive's framing bytes and the state the central directory
    needs; the caller writes member payloads itself. Nothing is buffered beyond
    the directory, so an archive of any size streams straight to a socket.

    Member sizes are unknown when a member starts, so members carry their CRC
    and sizes in a trailing data descriptor (general-purpose bit 3) and every
    archive is ZIP64 — no 4 GiB ceiling on members or on the archive.

    Per member: {!start_entry}, then {!feed} for each payload block, then
    {!end_entry}. {!finish} closes the archive. *)

type t

val create : unit -> t

(** Local file header for a member. [mtime] is a Unix timestamp; [mode] is the
    Unix permission bits recorded in the archive (default [0o644]). *)
val start_entry : t -> name:string -> mtime:float -> ?mode:int -> unit -> string

(** Record a directory member: header emitted and closed immediately, since a
    directory has no payload. A trailing "/" is added to [name] when absent. *)
val add_directory : t -> name:string -> mtime:float -> string

(** Account for one block of the current member's payload: the caller writes
    [block] to the output, this only advances the CRC and byte count. *)
val feed : t -> string -> unit

(** Data descriptor closing the current member. *)
val end_entry : t -> string

(** Central directory, ZIP64 end-of-central-directory record, ZIP64 locator and
    the end-of-central-directory record. *)
val finish : t -> string
