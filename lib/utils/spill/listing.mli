(** A sequence of records too long to hold, spilled to a {!Spool} and read back
    mapped.

    For a listing whose length the data chooses — the entries of a tree, the
    objects of a keyspace — where a caller needs to know how many there are
    before it starts and then to walk them once or twice. Fields are
    length-prefixed rather than delimited because a name is an arbitrary byte
    string and may hold whatever separator a reader picked. *)

(** The six things a listing takes from a spool, which is less than a spool has:
    a module with more is handed over as it stands. *)
module type SPOOL = sig
  type 'a io
  type t

  val create : dir:string -> name:string -> t io
  val append : t -> string -> unit io
  val seal : t -> Bigstring.t io
  val drop : t -> unit io
  val reap : dir:string -> unit io
end

(** A length-prefixed string, which {!read_string} reads back. *)
val str : Buffer.t -> string -> unit

val int64 : Buffer.t -> int64 -> unit
val read_string : Bigstring.t -> int ref -> string
val read_int64 : Bigstring.t -> int ref -> int64
val read_int : Bigstring.t -> int ref -> int

module Make (Io : Io.S) (Spool : SPOOL with type 'a io := 'a Io.t) : sig
  type 'a t

  (** [decode] reads one record from the mapped body, advancing the cursor past
      exactly the bytes {!add} wrote for it. *)
  val create :
    dir:string ->
    name:string ->
    decode:(Bigstring.t -> int ref -> 'a) ->
    'a t Io.t

  (** Append one record, each field written by one of [fields]. Raises once the
      spool is sealed: {!Bigstring.map_file} is sound for a file that stays as
      it was mapped, and the seal is where that begins. *)
  val add : 'a t -> (Buffer.t -> unit) list -> unit Io.t

  (** Records appended so far, which is a total a caller can announce before it
      walks them. *)
  val count : 'a t -> int

  (** Walk every record in the order they were added. The first call seals the
      spool, after which {!add} is an error and this may be called again — a
      caller with several destinations walks the same listing once for each. *)
  val iter : 'a t -> ('a -> unit Io.t) -> unit Io.t

  type 'a cursor

  (** A place in the listing, for a set of workers each taking the next record:
      they pull, where {!iter} pushes. Seals as {!iter} does. *)
  val read : 'a t -> 'a cursor Io.t

  (** The next record, or [None] at the end. Reads straight out of the mapping,
      so it holds between binds and can drive a worker loop. *)
  val next : 'a cursor -> 'a option

  val drop : 'a t -> unit Io.t

  (** Unlink the spools a killed run left under [dir]. *)
  val reap : dir:string -> unit Io.t
end
