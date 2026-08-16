(** One store's listing, on disk, walked once.

    A resync lists every namespace of every configured store, which on a real
    domain is millions of keys per listing and several listings at a time. Held
    as [Backend.file_entry list] that is hundreds of megabytes the collector
    scans and nothing reads twice. Here each page is appended to a temp file as
    it arrives and the finished file is mapped, so what is resident is the pages
    being compared rather than the domain.

    Written strictly ascending and read strictly forward, because the diff is a
    merge join and {!Backend.S.fold_prefix} owes its caller that order. *)

(** Open for append. *)
type t

(** Closed and mapped. *)
type sealed

type cursor

(** [previous] and [next] as the store listed them, and [spool] the label given
    at {!create}, so a report names which listing of which store regressed
    rather than only that something did. *)
exception Out_of_order of { spool : string; previous : string; next : string }

(** A uniquely named temp file under [dir], which is created. [label] is what a
    failure calls this listing — ["chunks on replica"]. *)
val create : dir:string -> label:string -> t Lwt.t

(** Append a page, in the order it arrived. A key equal to its predecessor is
    dropped, a store being free to repeat one across a page boundary; one below
    it raises {!Out_of_order} rather than letting a broken listing become a diff
    that copies the wrong objects. *)
val add : t -> Backend.file_entry list -> unit Lwt.t

(** Close and unlink a spool that will not be sealed. *)
val discard : t -> unit Lwt.t

(** Close the channel and map the whole file. Sealing precedes mapping and never
    the other way round: {!Chunk.map_file} is only sound for a file nothing
    rewrites in place, which this is exactly once its channel is closed. *)
val seal : t -> sealed Lwt.t

val count : sealed -> int

(** Unlink. The mapping stays valid — POSIX keeps the inode alive under it — so
    a run can remove every spool in one [Lwt.finalize] without tracking which
    ones are still being read. *)
val remove : sealed -> unit Lwt.t

val cursor : sealed -> cursor
val at_end : cursor -> bool
val advance : cursor -> unit
val size : cursor -> int

(** Allocates, so the copy path asks and the compare path does not. *)
val key : cursor -> string

(** {!Key.is_dir} answered from the mapping's own bytes, so a record that turns
    out to need nothing never becomes a string. *)
val key_is_dir : cursor -> bool

(** Lexicographic over the key bytes inside the two mappings, allocating
    nothing. Agrees with [String.compare], which is the order the stores list
    in. *)
val compare : cursor -> cursor -> int

(** Unlink spools a killed run left behind, the way the manifest cache reaps its
    own. *)
val sweep : dir:string -> unit Lwt.t
