(** A sequence of records too long to hold, spilled to a {!Spool} and read back
    mapped.

    For a listing whose length the data chooses — the entries of a tree, the
    objects of a keyspace — where a caller needs to know how many there are
    before it starts and then to walk them once or twice. Fields are
    length-prefixed rather than delimited because a name is an arbitrary byte
    string and may hold whatever separator a reader picked. *)

type 'a t

(** [decode] reads one record from the mapped body, advancing the cursor past
    exactly the bytes {!add} wrote for it. *)
val create :
  dir:string -> name:string -> decode:(Chunk.t -> int ref -> 'a) -> 'a t Lwt.t

(** Append one record, each field written by one of [fields]. Raises once
    {!iter} has been called: appending to a sealed spool is the one mistake the
    mapping cannot survive. *)
val add : 'a t -> (Buffer.t -> unit) list -> unit Lwt.t

(** Records appended so far, which is a total a caller can announce before it
    walks them. *)
val count : 'a t -> int

(** Walk every record in the order they were added. The first call seals the
    spool, after which {!add} is an error and this may be called again — a
    caller with several destinations walks the same listing once for each. *)
val iter : 'a t -> ('a -> unit Lwt.t) -> unit Lwt.t

val drop : 'a t -> unit Lwt.t

(** Unlink the spools a killed run left under [dir]. *)
val reap : dir:string -> unit Lwt.t

(** A length-prefixed string, which {!read_string} reads back. *)
val str : Buffer.t -> string -> unit

val int64 : Buffer.t -> int64 -> unit
val read_string : Chunk.t -> int ref -> string
val read_int64 : Chunk.t -> int ref -> int64
