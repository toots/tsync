(** Files of a domain written out as plain files, read straight off its stores:
    no daemon, no local mirror, and nothing put in the cache but a record of
    what is still in flight.

    Built for files too large to pass through a cache: each is given its blocks
    before its first byte, filled chunk by chunk in whatever order they arrive,
    every chunk checked against its key, and resumed where it stopped. What this
    machine has not uploaded yet is not on a store and is not exported. *)

type outcome =
  [ `Exported | `Exported_symlink | `Already_there | `Failed of string ]

(** [present] is what of [bytes] is on the disk already, from an earlier run. *)
type planned = { files : int; bytes : int64; present : int64 }

(** A file being picked up: [present] of its [size] landed in an earlier run. *)
type started = { rel : string; size : int64; present : int64 }

(** [`Landed] carries the file's domain-relative path and the bytes just
    written; [`Finished] comes once a file. *)
type event =
  [ `Plan of planned
  | `Started of started
  | `Landed of string * int
  | `Finished of string * outcome ]

(** [pending] names what is staged on this machine under the paths asked for,
    which an export off the stores does not hold. *)
type summary = {
  exported : int;
  already_there : int;
  failed : int;
  pending : string list;
}

(** {1 The pieces, exposed for the tests that pin them} *)

(** What has landed of one file, kept under {!Cache_layout.exports_dir} so the
    folder exported to holds nothing but the export: a header naming the content
    and the destination, then the index of each chunk written and synced. *)
module Record : sig
  type identity = {
    h1 : string;
    h2 : string;
    size : int64;
    chunk_size : int;
    dst : string;
  }

  val header : identity -> string
  val claim : int -> string

  (** [`Mismatch] for a record of other content or another destination. *)
  val parse :
    count:int -> identity -> string -> [ `Claimed of Bytes.t | `Mismatch ]

  val is_claimed : Bytes.t -> int -> bool
  val claimed_count : Bytes.t -> int
end

type on_disk = { size : int64; mtime : float }

(** What to do with one file, from its record and what is at its destination. A
    record is believed only beside a file of the right length; with none, a file
    of the manifest's size and mtime is the finished one. *)
val decide :
  count:int ->
  identity:Record.identity ->
  mtime:float ->
  record:string option ->
  dst:on_disk option ->
  [ `Resume of Bytes.t | `Fresh | `Already_there ]

(** Where [rel] lands under [dst] when [asked] is what named it: a file by its
    own name, a folder's contents under the folder's, the root's as they are. *)
val landing : dst:string -> asked:string -> rel:string -> string

module Over
    (Io : Io.S)
    (Files : Fs.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t and type fd = Files.fd)
    (Pools : Bounded.S with type 'a io := 'a Io.t)
    (_ : Inode_tree.OVER with type 'a io := 'a Io.t and type pool := Pools.t)
    (_ : Staged_manifest.OVER with type 'a io := 'a Io.t)
    (_ : Remote.OVER with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** Export what [paths] name — a file each, or a folder's subtree, [[]]
        being the whole domain — under the absolute [dst].

        Fails when a path names nothing or two of them land on one file; past
        that a file that cannot be had costs only itself, and is counted. *)
    val run :
      ?on_event:(event -> unit) ->
      dst:string ->
      paths:string list ->
      unit ->
      summary Io.t
  end
end
