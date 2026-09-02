(** An append-only temp file, then a mapping of it.

    A job too large to hold in memory spills to one of these and reads it back
    mapped. The order is not a detail that reads as a bug when got wrong:
    {!Bigstring.map_file} is sound only for a file nothing rewrites in place, so
    the channel is closed before the mapping is made, and a file still open for
    append is exactly what that rules out. *)

(** The buffered writer nothing here can supply: a channel is state, and the
    stream-to-stream copy behind {!Make.append_file} is not a sequence of reads
    and writes this could spell for itself. *)
module type APPEND = sig
  type 'a io
  type t

  val open_out : string -> t io
  val write : t -> string -> unit io

  (** Append the whole of [src], which must already be flushed. *)
  val write_file : t -> src:string -> unit io

  val close : t -> unit io
end

module Make
    (Io : Io.S)
    (Files : Fs.S with type 'a io := 'a Io.t)
    (Append : APPEND with type 'a io := 'a Io.t) : sig
  type t

  (** An empty temp file under [dir], which is created; [name] only makes the
      path readable. *)
  val create : dir:string -> name:string -> t Io.t

  val path : t -> string
  val append : t -> string -> unit Io.t

  (** Append the whole contents of [src], which must already be flushed. *)
  val append_file : t -> src:string -> unit Io.t

  (** Close the channel and map the whole finished file. Fails naming the spool
      if it is no longer there to be stat'd. *)
  val seal : t -> Bigstring.t Io.t

  (** Close without mapping, for a spool whose bytes are read another way. *)
  val close : t -> unit Io.t

  (** Close and unlink, swallowing a channel already closed. *)
  val drop : t -> unit Io.t

  (** Unlink the spools a killed run left under [dir], one level only. *)
  val reap : dir:string -> unit Io.t
end
