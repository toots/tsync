(** A folder's children's bodies, cached in one object beside them.

    A resync reads a folder by listing it and then reading every child, which on
    a store with no multi-object read is a round trip apiece. This holds those
    bodies together so the listing is followed by one read instead.

    {b The listing stays the truth.} An entry here is used only when the listing
    still reports the version it was recorded under, so a stale, missing or
    unreadable index costs reads and never correctness — and it costs them per
    child rather than per folder. Nothing on the write path maintains it: a
    rename, a delete or another client's upload simply show up in the listing as
    entries this does not cover.

    Only children whose listing named a version ({!Backend.file_entry.etag}) are
    held. Size and modification time are not enough to tell a body from its
    replacement — S3 reports whole seconds — and a store that names no version
    is one where this cannot be safe, so on one it holds nothing and every child
    is read as it would have been. *)

type t

val empty : t

(** The body recorded for [key] under version [etag], if that is the version
    this holds. *)
val find : t -> key:string -> etag:string -> string option

(** What a reader will pull down. {!worth_writing} governs only what this build
    writes; an index left by another client, or by a build whose bound differed,
    is still on the store and would be read whole. A listing names its size, so
    a caller can pass over one past this without fetching it. *)
val max_bytes : int

(** Raises [Failure] on anything this did not write, which a caller treats as an
    index it does not have. *)
val of_string : string -> t

(** Children carrying a version, and nothing else. *)
val of_bodies : (Backend.file_entry * string) list -> string

(** Whether writing [covered] of [total] children back is worth the round trip
    it costs. Decided here so no caller invents its own threshold, and [false]
    for a folder with nothing worth holding — or with so much that holding it
    costs more memory than the reads it saves. *)
val worth_writing : covered:int -> total:int -> bool
